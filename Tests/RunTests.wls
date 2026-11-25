Needs["MUnit`"];


$root = DirectoryName[$InputFileName, 2];
Get[FileNameJoin[{$root, "Kernel", "WebSocket.wl"}]];
$failed = 0;
Scan[Function[file,
    report = Get[FileNameJoin[{$root, "Tests", file}]];
    If[!MatchQ[report, _TestReportObject], Print["Invalid test report: ", file]; Exit[1]];
    Print[file, ": ", report["TestsSucceededCount"], " passed; ", report["TestsFailedCount"], " failed"];
    $failed += report["TestsFailedCount"];
    If[report["TestsFailedCount"] > 0, Print[report["TestsFailed"]]]
], {"WebSocket.wlt", "CSockets.wlt"}];
If[$failed > 0, Exit[1]];
