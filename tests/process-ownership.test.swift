@main
enum ProcessOwnershipTests {
    static func main() {
        let scripts: [(pid: Int32, ppid: Int32, command: String)] = [
            (31296, 31215, "script"),
            (31215, 31206, "script"),
            (31300, 31296, "script"),
            (40000, 1, "script"),
            (40001, 40000, "script"),
            (50000, 50001, "script")
        ]
        let managed = SessionProcessOwnership.managedScriptPIDs(
            currentScriptPID: 31215, launcherPID: 31206, scripts: scripts
        )
        precondition(managed == [31215, 31296, 31300])
        precondition(Set(scripts.map(\.pid)).subtracting(managed) == [40000, 40001, 50000])
        precondition(SessionProcessOwnership.managedScriptPIDs(
            currentScriptPID: nil, launcherPID: 31206, scripts: scripts
        ).isEmpty)
        precondition(SessionProcessOwnership.managedScriptPIDs(
            currentScriptPID: 31215, launcherPID: 99999, scripts: scripts
        ).isEmpty)
        precondition(SessionProcessOwnership.managedScriptPIDs(
            currentScriptPID: 99999, launcherPID: 31206, scripts: scripts
        ).isEmpty)
        print("Process ownership tests passed")
    }
}
