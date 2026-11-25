#!/usr/bin/env wolframscript
(* ::Package:: *)

PacletDirectoryLoad[Directory[]];
Get["KirillBelov`WebSocket`"];


server = WebSocketServerCreate[8080, <|
    "Echo" -> (Function[True] -> Function[{client, message}, message])
|>];


connection = WebSocketConnect["ws://localhost:8080"];
WebSocketSend[connection, "hello"];
SocketReadyQ[connection, 1];
Print[SocketReadMessage[connection]];
WebSocketSend[connection, ByteArray[{0, 128, 255}]];
SocketReadyQ[connection, 1];
Print[SocketReadMessage[connection]];
Close[connection];
Close[server];
