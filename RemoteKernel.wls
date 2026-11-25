#!/usr/bin/env wolframscript

PacletDirectoryLoad[Directory[]];
Get["KirillBelov`WebSocket`"];


ws = WebSocketServerCreate[8080, <||>,
    "DefaultMessageHandler" -> Function[{client, message}, Echo[message, "MSG:"]; Null]
];


While[True, Pause[1]];
