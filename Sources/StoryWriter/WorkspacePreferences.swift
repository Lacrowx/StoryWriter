import Foundation

/// Navigation belongs to this Mac, rather than to a portable manuscript or revision.
struct WorkspacePreferences {
    var root: URL
    var defaults: UserDefaults = .standard

    private var prefix: String { "workspace." + root.standardizedFileURL.path + "." }

    var projectID: UUID? {
        get { defaults.string(forKey: prefix + "project").flatMap(UUID.init(uuidString:)) }
        nonmutating set { defaults.set(newValue?.uuidString, forKey: prefix + "project") }
    }

    func chapterID(in project: StoryProject) -> UUID? {
        let saved = defaults.string(forKey: prefix + project.id.uuidString + ".chapter").flatMap(UUID.init(uuidString:))
        return project.chapters.first(where: { $0.id == saved })?.id ?? project.chapters.first?.id
    }

    func rememberChapter(_ id: UUID?, in projectID: UUID) {
        defaults.set(id?.uuidString, forKey: prefix + projectID.uuidString + ".chapter")
    }

    func section(in projectID: UUID) -> WorkspaceSection {
        defaults.string(forKey: prefix + projectID.uuidString + ".section").flatMap(WorkspaceSection.init(rawValue:)) ?? .manuscript
    }

    func rememberSection(_ section: WorkspaceSection, in projectID: UUID) {
        defaults.set(section.rawValue, forKey: prefix + projectID.uuidString + ".section")
    }
}
