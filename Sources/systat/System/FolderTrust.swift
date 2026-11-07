import Foundation

/// Whether only this user, root, or an admin (who can become root anyway) can change a folder.
///
/// The update helper empties the app's slot for a moment and then opens whatever is there. Anyone
/// else who can add, rename or remove entries in the app's folder, or in any folder above it,
/// could fill that slot with their own app and have it launched as this user.
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

    private static func isTrusted(_ path: String) -> Bool {
        // A volume that ignores ownership reports every file as owned by whoever asks.
        var volume = statfs()
        guard statfs(path, &volume) == 0, volume.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0 else { return false }
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

    /// Any ACL entry that allows adding, removing or renaming entries, or changing the folder's
    /// permissions. Deny entries (like a home folder's "everyone deny delete") take nothing away.
    private static func aclLetsSomeoneChange(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
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
            if changes.contains(where: { acl_get_perm_np(permissions, $0) == 1 }) { return true }
        }
        return false
    }
}
