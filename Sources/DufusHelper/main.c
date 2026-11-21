// DufusHelper: lets Dufus write disks without a password prompt each time.
//
// "Install Disk Helper" in the app menu puts it setuid root at
// /Library/PrivilegedHelperTools/com.github.tenox7.dufus.helper.
// Like `authopen -stdoutpipe`, it opens one disk read/write and sends the
// descriptor back over stdout (a unix socket). All data still flows through
// the app. It refuses unless:
//   - the user is an admin,
//   - the caller is Dufus, signed by the same team as this helper,
//   - the disk is a whole disk with removable media (no fixed HDD/SSD, no disk image),
//   - no volume of the disk is mounted (this also protects the boot disk).
// `DufusHelper --check /dev/rdiskN` runs the checks without opening the disk.

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOBSD.h>
#include <IOKit/IOKitLib.h>
#include <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <membership.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define APP_ID "com.github.tenox7.dufus"
#define ADMIN_GID 80

static void fail(const char *why) {
    fprintf(stderr, "DufusHelper: %s\n", why);
    exit(1);
}

// "/dev/rdiskN" -> "diskN". Whole disks only.
static int parse_disk(const char *path, char *bsd, size_t len) {
    static const char prefix[] = "/dev/rdisk";
    if (strncmp(path, prefix, sizeof prefix - 1) != 0) return 0;
    const char *num = path + sizeof prefix - 1;
    size_t digits = strspn(num, "0123456789");
    if (digits == 0 || digits > 3 || num[digits] != '\0') return 0;
    snprintf(bsd, len, "disk%s", num);
    return 1;
}

static int user_is_admin(void) {
    uuid_t user, group;
    int member = 0;
    return mbr_uid_to_uuid(getuid(), user) == 0 && mbr_gid_to_uuid(ADMIN_GID, group) == 0 &&
           mbr_check_membership(user, group, &member) == 0 && member;
}

// Team ID this helper is signed with. NULL when ad-hoc signed.
static CFStringRef copy_own_team(void) {
    SecCodeRef self = NULL;
    SecStaticCodeRef code = NULL;
    CFDictionaryRef info = NULL;
    CFStringRef team = NULL;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &self) == errSecSuccess &&
        SecCodeCopyStaticCode(self, kSecCSDefaultFlags, &code) == errSecSuccess &&
        SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info) == errSecSuccess) {
        team = CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier);
        if (team) CFRetain(team);
    }
    if (info) CFRelease(info);
    if (code) CFRelease(code);
    if (self) CFRelease(self);
    return team;
}

// The process on the other end of stdout must be Dufus, signed by our team.
static int caller_is_dufus(void) {
    audit_token_t token;
    socklen_t len = sizeof token;
    if (getsockopt(STDOUT_FILENO, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) != 0) return 0;
    CFStringRef team = copy_own_team();
    if (!team) return 0;
    CFStringRef text = CFStringCreateWithFormat(NULL, NULL,
        CFSTR("identifier \"" APP_ID "\" and anchor apple generic and certificate leaf[subject.OU] = \"%@\""), team);
    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)&token, sizeof token);
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, (const void **)&kSecGuestAttributeAudit, (const void **)&data, 1,
                                               &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecRequirementRef req = NULL;
    SecCodeRef caller = NULL;
    int ok = SecRequirementCreateWithString(text, kSecCSDefaultFlags, &req) == errSecSuccess &&
             SecCodeCopyGuestWithAttributes(NULL, attrs, kSecCSDefaultFlags, &caller) == errSecSuccess &&
             SecCodeCheckValidity(caller, kSecCSDefaultFlags, req) == errSecSuccess;
    if (caller) CFRelease(caller);
    if (req) CFRelease(req);
    CFRelease(attrs);
    CFRelease(data);
    CFRelease(text);
    CFRelease(team);
    return ok;
}

static io_service_t media_named(const char *bsd) {
    return IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd));
}

static int prop_true(io_registry_entry_t e, CFStringRef key) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, key, NULL, 0);
    int r = v && CFEqual(v, kCFBooleanTrue);
    if (v) CFRelease(v);
    return r;
}

static int dict_has(CFDictionaryRef d, CFStringRef key, CFStringRef value) {
    CFTypeRef v = CFDictionaryGetValue(d, key);
    return v && CFEqual(v, value);
}

// Whole disk with removable media (SD/CF cards, most USB sticks), not a disk image.
// Fixed disks are refused, internal or external (HDD, SSD, Time Machine), even when ejectable.
static int disk_allowed(io_service_t media) {
    if (!prop_true(media, CFSTR("Whole")) || !prop_true(media, CFSTR("Removable"))) return 0;
    io_registry_entry_t e = media, parent;
    IOObjectRetain(e);
    int ok = 0;
    while (IORegistryEntryGetParentEntry(e, kIOServicePlane, &parent) == KERN_SUCCESS) {
        IOObjectRelease(e);
        e = parent;
        if (!IOObjectConformsTo(e, "IOBlockStorageDevice")) continue;
        CFTypeRef pc = IORegistryEntryCreateCFProperty(e, CFSTR("Protocol Characteristics"), NULL, 0);
        if (pc && CFGetTypeID(pc) == CFDictionaryGetTypeID())
            ok = !dict_has(pc, CFSTR("Physical Interconnect"), CFSTR("Virtual Interface")) &&
                 !dict_has(pc, CFSTR("Physical Interconnect"), CFSTR("Disk Image"));
        if (pc) CFRelease(pc);
        break;
    }
    IOObjectRelease(e);
    return ok;
}

// True if media `child` is `disk` or sits on it (partition, APFS container, volume).
static int on_disk(const char *child, CFStringRef disk) {
    io_registry_entry_t e = media_named(child), parent;
    int found = 0;
    while (e && !found) {
        CFTypeRef name = IORegistryEntryCreateCFProperty(e, CFSTR(kIOBSDNameKey), NULL, 0);
        found = name && CFEqual(name, disk);
        if (name) CFRelease(name);
        if (IORegistryEntryGetParentEntry(e, kIOServicePlane, &parent) != KERN_SUCCESS) parent = 0;
        IOObjectRelease(e);
        e = parent;
    }
    if (e) IOObjectRelease(e);
    return found;
}

static int has_mounted_volume(const char *bsd) {
    int n = getfsstat(NULL, 0, MNT_NOWAIT);
    if (n <= 0) return 1;
    struct statfs *mnt = calloc((size_t)n, sizeof *mnt);
    if (!mnt) return 1;
    n = getfsstat(mnt, n * (int)sizeof *mnt, MNT_NOWAIT);
    CFStringRef disk = CFStringCreateWithCString(NULL, bsd, kCFStringEncodingUTF8);
    int busy = n < 0;
    for (int i = 0; i < n && !busy; i++)
        if (strncmp(mnt[i].f_mntfromname, "/dev/disk", 9) == 0)
            busy = on_disk(mnt[i].f_mntfromname + 5, disk);
    CFRelease(disk);
    free(mnt);
    return busy;
}

static int send_fd(int sock, int fd) {
    char byte = 0;
    struct iovec iov = {.iov_base = &byte, .iov_len = 1};
    union {
        struct cmsghdr hdr;
        char buf[CMSG_SPACE(sizeof(int))];
    } ctl;
    memset(&ctl, 0, sizeof ctl);
    struct msghdr msg = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctl.buf, .msg_controllen = sizeof ctl.buf};
    struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
    c->cmsg_level = SOL_SOCKET;
    c->cmsg_type = SCM_RIGHTS;
    c->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(c), &fd, sizeof(int));
    return sendmsg(sock, &msg, 0) == 1 ? 0 : -1;
}

int main(int argc, char **argv) {
    // setuid hygiene: never let open() land on a closed stdin/stdout/stderr.
    for (int fd = 0; fd <= 2; fd++)
        if (fcntl(fd, F_GETFD) == -1 && open("/dev/null", O_RDWR) != fd) return 1;

    int check = argc == 3 && strcmp(argv[1], "--check") == 0;
    char bsd[16];
    if (argc != 2 + check || !parse_disk(argv[1 + check], bsd, sizeof bsd))
        fail("usage: DufusHelper [--check] /dev/rdiskN");
    const char *path = argv[1 + check];

    if (!user_is_admin()) fail("user is not an admin");
    if (!caller_is_dufus()) fail("caller is not Dufus signed by the same team");
    io_service_t media = media_named(bsd);
    if (!media) fail("no such disk");
    int allowed = disk_allowed(media);
    IOObjectRelease(media);
    if (!allowed) fail("not a removable disk");
    if (has_mounted_volume(bsd)) fail("disk has mounted volumes");
    if (check) {
        fprintf(stderr, "DufusHelper: ok\n");
        return 0;
    }

    if (geteuid() != 0) fail("not installed setuid root");
    int fd = open(path, O_RDWR);
    if (fd < 0) fail(strerror(errno));
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISCHR(st.st_mode)) fail("not a disk device");
    if (send_fd(STDOUT_FILENO, fd) != 0) fail("cannot send descriptor");
    return 0;
}
