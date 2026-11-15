enum SessionProcessOwnership {
    // Only follow matching launch-script processes rooted in this launcher.
    // Detached scripts and children of another launcher remain reportable.
    static func managedScriptPIDs(
        currentScriptPID: Int32?,
        launcherPID: Int32,
        scripts: [(pid: Int32, ppid: Int32, command: String)]
    ) -> Set<Int32> {
        guard let root = currentScriptPID,
              scripts.contains(where: { $0.pid == root && $0.ppid == launcherPID }) else { return [] }
        var managed: Set<Int32> = [root]
        var previousCount = 0
        while previousCount != managed.count {
            previousCount = managed.count
            for script in scripts where managed.contains(script.ppid) {
                managed.insert(script.pid)
            }
        }
        return managed
    }
}
