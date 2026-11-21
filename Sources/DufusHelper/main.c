// DufusHelper: lets Dufus write disks without a password prompt each time.
//
// "Install Disk Helper" in the app menu puts it setuid root at
// /Library/PrivilegedHelperTools/com.github.tenox7.dufus.helper.
// Like `authopen -stdoutpipe`, it opens one disk read/write and sends the
// descriptor back over stdout (a unix socket). All data still flows through
// the app. It refuses unless:
//   - the path is /dev/rdiskN (a whole raw disk),
//   - the user is an admin,
//   - the caller is Dufus, signed by the same team as this helper,
//   - the disk is a physical whole disk with removable media (SD/CF cards, most USB sticks):
//     no fixed HDD or SSD, no disk image, no synthesized (APFS) disk,
//   - no volume of the disk is mounted (this also protects the boot disk).
// The checks run as the user. Only the open() runs as root, then the helper drops root for good
// and checks the opened disk again, so a disk swapped in meanwhile cannot slip through.
// `DufusHelper --check /dev/rdiskN` runs the checks without opening the disk.

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOBSD.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/IOMedia.h>
#include <IOKit/storage/IOStorageProtocolCharacteristics.h>
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
#include <sys/types.h>
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

// The provider of `e`, or 0. Releases `e`.
static io_registry_entry_t parent_of(io_registry_entry_t e) {
    io_registry_entry_t parent;
    if (IORegistryEntryGetParentEntry(e, kIOServicePlane, &parent) != KERN_SUCCESS) parent = 0;
    IOObjectRelease(e);
    return parent;
}

static int prop_true(io_registry_entry_t e, CFStringRef key) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, key, NULL, 0);
    int r = v && CFEqual(v, kCFBooleanTrue);
    if (v) CFRelease(v);
    return r;
}

static int prop_int(io_registry_entry_t e, CFStringRef key, int *out) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, key, NULL, 0);
    int r = v && CFGetTypeID(v) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, out);
    if (v) CFRelease(v);
    return r;
}

static int name_is(io_registry_entry_t e, CFStringRef name) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, CFSTR(kIOBSDNameKey), NULL, 0);
    int r = v && CFEqual(v, name);
    if (v) CFRelease(v);
    return r;
}

static int dict_has(CFDictionaryRef d, CFStringRef key, CFStringRef value) {
    CFTypeRef v = CFDictionaryGetValue(d, key);
    return v && CFEqual(v, value);
}

// A physical whole disk sits right on its driver and device: IOMedia <- IOBlockStorageDriver <- IOBlockStorageDevice,
// and the device has a real interconnect. Disk images have a virtual device (and say they are removable).
// Synthesized disks (APFS containers) sit on a partition, not on a driver.
static int physical_disk(io_registry_entry_t media) {
    IOObjectRetain(media);
    io_registry_entry_t driver = parent_of(media);
    if (!driver) return 0;
    if (!IOObjectConformsTo(driver, "IOBlockStorageDriver")) {
        IOObjectRelease(driver);
        return 0;
    }
    io_registry_entry_t device = parent_of(driver);
    if (!device) return 0;
    int ok = 0;
    if (IOObjectConformsTo(device, "IOBlockStorageDevice")) {
        CFTypeRef pc = IORegistryEntryCreateCFProperty(device, CFSTR(kIOPropertyProtocolCharacteristicsKey), NULL, 0);
        if (pc && CFGetTypeID(pc) == CFDictionaryGetTypeID()) {
            CFDictionaryRef d = pc;
            CFStringRef type = CFSTR(kIOPropertyPhysicalInterconnectTypeKey);
            CFStringRef where = CFSTR(kIOPropertyPhysicalInterconnectLocationKey);
            ok = CFDictionaryContainsKey(d, type) &&
                 !dict_has(d, type, CFSTR(kIOPropertyPhysicalInterconnectTypeVirtual)) &&
                 !dict_has(d, type, CFSTR("Disk Image")) &&
                 !dict_has(d, where, CFSTR(kIOPropertyInterconnectFileKey)) &&
                 !dict_has(d, where, CFSTR(kIOPropertyInterconnectRAMKey));
        }
        if (pc) CFRelease(pc);
    }
    IOObjectRelease(device);
    return ok;
}

// True if `child` (a BSD name) is the disk `disk` or sits on it: partition, APFS container, volume.
static int on_disk(const char *child, const char *disk) {
    size_t n = strlen(disk);
    if (strncmp(child, disk, n) == 0 && (child[n] == '\0' || child[n] == 's')) return 1;
    CFStringRef name = CFStringCreateWithCString(NULL, disk, kCFStringEncodingUTF8);
    io_registry_entry_t e = media_named(child);
    int found = 0;
    while (e && !found) {
        found = name_is(e, name);
        e = parent_of(e);
    }
    if (e) IOObjectRelease(e);
    CFRelease(name);
    return found;
}

static int has_mounted_volume(const char *disk) {
    int n = getfsstat(NULL, 0, MNT_NOWAIT);
    if (n <= 0) return 1;
    int room = n + 16;
    struct statfs *mnt = calloc((size_t)room, sizeof *mnt);
    if (!mnt) return 1;
    n = getfsstat(mnt, room * (int)sizeof *mnt, MNT_NOWAIT);
    int busy = n < 0 || n >= room;  // when in doubt, say busy
    for (int i = 0; i < n && !busy; i++) {
        const char *from = mnt[i].f_mntfromname;
        if (strncmp(from, "/dev/", 5) == 0) from += 5;
        if (strncmp(from, "disk", 4) == 0) busy = on_disk(from, disk);
    }
    free(mnt);
    return busy;
}

// Why `bsd` may not be opened, or NULL if it may. `dev` gets its device number.
static const char *check_disk(const char *bsd, dev_t *dev) {
    io_service_t media = media_named(bsd);
    if (!media) return "no such disk";
    int maj, min;
    const char *why = NULL;
    if (!IOObjectConformsTo(media, kIOMediaClass) || !prop_int(media, CFSTR(kIOBSDMajorKey), &maj) ||
        !prop_int(media, CFSTR(kIOBSDMinorKey), &min) || !prop_true(media, CFSTR(kIOMediaWholeKey)))
        why = "not a whole disk";
    else if (!prop_true(media, CFSTR(kIOMediaRemovableKey))) why = "not a removable disk";
    else if (!physical_disk(media)) why = "not a physical disk";
    else if (has_mounted_volume(bsd)) why = "disk has mounted volumes";
    else *dev = makedev(maj, min);
    IOObjectRelease(media);
    return why;
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

    // Run as the user. Root comes back only for the open() below.
    uid_t user = getuid();
    int root = geteuid() == 0;
    if (root && seteuid(user) != 0) fail("cannot drop root");

    int check = argc == 3 && strcmp(argv[1], "--check") == 0;
    char bsd[16];
    if (argc != 2 + check || !parse_disk(argv[1 + check], bsd, sizeof bsd))
        fail("usage: DufusHelper [--check] /dev/rdiskN");

    if (!user_is_admin()) fail("user is not an admin");
    if (!caller_is_dufus()) fail("caller is not Dufus signed by the same team");
    dev_t dev = 0;
    const char *why = check_disk(bsd, &dev);
    if (why) fail(why);
    if (check) {
        fprintf(stderr, "DufusHelper: ok\n");
        return 0;
    }

    if (!root) fail("not installed setuid root");
    char path[32];
    snprintf(path, sizeof path, "/dev/r%s", bsd);
    if (seteuid(0) != 0) fail("cannot get root");
    int fd = open(path, O_RDWR | O_NOFOLLOW);
    int err = errno;
    if (setuid(user) != 0) fail("cannot drop root");  // for good
    if (fd < 0) fail(strerror(err));

    // Check the disk that was really opened. The open keeps its device number in use,
    // so if another disk took the name meanwhile, the numbers do not match.
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISCHR(st.st_mode)) fail("not a disk device");
    why = check_disk(bsd, &dev);
    if (why) fail(why);
    if (st.st_rdev != dev) fail("disk changed while opening");
    if (send_fd(STDOUT_FILENO, fd) != 0) fail("cannot send descriptor");
    return 0;
}
