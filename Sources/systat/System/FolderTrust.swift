import Darwin.membership
import Foundation

/// Whether only this user, root, or an admin can change a folder. Admins count because another admin
/// can already replace anything in `/Applications` (root:admin, group-writable) without the updater.
///
/// The updater checks the app's folder, then swaps the new app in and opens it there. Anyone else who
/// can add, rename or remove entries in that folder, or in any folder above it, could put their own
/// app in its place, or swap the folder, between the checks and the launch.
enum FolderTrust {
    /// `folder` and every folder above it, after resolving links.
    static func onlyTrustedCanChange(_ folder: URL) -> Bool {
        guard let real = realpath(folder.path, nil) else { return false }
        var path = String(cString: real)
        free(real)
        while true {
            guard isTrusted(path) else { return false }
            if path == "/" { return true }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    private static let adminGroup: gid_t = getgrnam("admin")?.pointee.gr_gid ?? 80

    /// A local volume that keeps ownership, mounted by the system or by this user. One that ignores
    /// ownership reports every file as owned by whoever asks, a network share reports what the mount
    /// says, whatever its server lets others do, and a disk image another user attached (at a folder
    /// of theirs) holds whatever owners they gave its files, this user's included.
    static func volumeIsTrusted(flags: UInt32, mountedBy owner: uid_t) -> Bool {
        flags & UInt32(MNT_LOCAL) != 0 && flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0 && (owner == 0 || owner == getuid())
    }

    private static func namesOnlyThisUser(_ entry: acl_entry_t) -> Bool {
        guard let qualifier = acl_get_qualifier(entry) else { return false }
        defer { acl_free(qualifier) }
        var me = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        guard mbr_uid_to_uuid(getuid(), &me) == 0 else { return false }
        // The qualifier is a user or group UUID; only this user's own matches.
        return withUnsafeBytes(of: &me) { memcmp($0.baseAddress, qualifier, 16) == 0 }
    }

    private static func isTrusted(_ path: String) -> Bool {
        var volume = statfs()
        guard statfs(path, &volume) == 0, volumeIsTrusted(flags: volume.f_flags, mountedBy: volume.f_owner) else { return false }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        let mode = info.st_mode
        let byMode = switch info.st_uid {
        // This user's own folder: its group (staff) may include other users.
        case getuid(): mode & 0o022 == 0
        // A system folder: group write only for wheel or admin, like /Applications.
        case 0: mode & 0o002 == 0 && (mode & 0o020 == 0 || info.st_gid == 0 || info.st_gid == adminGroup)
        default: false
        }
        return byMode && !aclLetsSomeoneChange(path)
    }

    /// Any ACL entry that allows someone other than this user to add, remove or rename entries, or
    /// change the folder's permissions. Deny entries (like a home folder's "everyone deny delete")
    /// take nothing away, and an entry naming only this user gives nobody else anything. A group
    /// counts even when this user is in it. Inherit-only entries count too: they grant nothing here,
    /// but the staging and run folders the updater creates inside would inherit them.
    static func aclLetsSomeoneChange(_ path: String) -> Bool {
        // No ACL at all is ENOENT; one that can't be read can't be vouched for.
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return errno != ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let changes = [ACL_ADD_FILE, ACL_ADD_SUBDIRECTORY, ACL_DELETE_CHILD, ACL_DELETE, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER]
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, which, &entry) == 0, let entry {
            which = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_t?
            guard acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_ALLOW,
                  acl_get_permset(entry, &permissions) == 0, let permissions else { continue }
            if changes.contains(where: { acl_get_perm_np(permissions, $0) == 1 }), !namesOnlyThisUser(entry) { return true }
        }
        return false
    }
}
