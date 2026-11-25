Needs["MUnit`"];
Needs["WLJS`CSockets`"];


report = TestReport[{
    VerificationTest[
        Block[{WLJS`CSockets`Private`socketSend = Function[{id, bytes}, AppendTo[sent, bytes]; Length[bytes]], sent = {}},
            Module[{ws, transport, input, result},
                ws = WebSocketHandler["Handshake" -> False, "DefaultMessageHandler" -> Function[{client, message}, message]];
                transport = CSocketHandler["Received" -> Function[ws[#]], "Closed" -> Function[ws[#]]];
                input = Join[WebSocketFrame["text", "Masking" -> True], WebSocketFrame[ByteArray[{0, 255}], "Masking" -> True]];
                result = transport[<|"Event" -> "Received", "SourceSocket" -> CSocketObject[42], "DataByteArray" -> input|>];
                {result["Result"], sent}
            ]
        ],
        With[{bytes = Join[WebSocketFrame["text"], WebSocketFrame[ByteArray[{0, 255}]]]}, {bytes, {bytes}}],
        TestID -> "CSockets Received sends encoded response once"
    ],
    VerificationTest[
        Block[{WLJS`CSockets`Private`socketSend = Function[{id, bytes}, AppendTo[sent, bytes]; Length[bytes]], sent = {}},
            Module[{ws, transport, input, result},
                ws = WebSocketHandler["Handshake" -> False, "DefaultMessageHandler" -> Function[{client, message}, message]];
                transport = CSocketHandler["Received" -> Function[ws[#]]];
                input = Normal[WebSocketFrame[StringRepeat["x", 126], "Masking" -> True]];
                Scan[transport[<|"Event" -> "Received", "SourceSocket" -> CSocketObject[42], "DataByteArray" -> ByteArray[{#}]|>]&, input];
                sent
            ]
        ],
        {WebSocketFrame[StringRepeat["x", 126]]},
        TestID -> "CSockets single-byte chunks do not fix an incomplete frame length"
    ]
}];


report


loopback = VerificationTest[
    Module[{server, client, port = RandomInteger[{20000, 60000}], text, binary, pushed, result},
        server = WebSocketServerCreate["127.0.0.1", port, <|"Echo" -> (Function[True] -> Function[{id, message}, message])|>];
        client = WebSocketConnect["ws://127.0.0.1:" <> ToString[port] <> "/chat?q=yes"];
        If[Head[client] =!= WebSocketConnection, Close[server]; Return[$Failed]];
        WebSocketSend[client, "Привет 🌍"];
        SocketReadyQ[client, 1];
        text = SocketReadMessage[client];
        WebSocketSend[client, ByteArray[{0, 128, 255}]];
        SocketReadyQ[client, 1];
        binary = SocketReadMessage[client];
        WebSocketSend[First[server["Connections"]["Elements"]], "push", "Masking" -> False];
        SocketReadyQ[client, 1];
        pushed = SocketReadMessage[client];
        result = {text, binary, pushed};
        Close[client];
        Close[server];
        result
    ],
    {"Привет 🌍", ByteArray[{0, 128, 255}], "push"},
    TestID -> "real loopback client server text binary"
];


closeAdapter = VerificationTest[
    Module[{handler = WebSocketHandler["Handshake" -> False], actions = {}},
        handler["SendFunction"] = Function[{client, bytes}, AppendTo[actions, {"Send", client, bytes}]; Null];
        handler["CloseFunction"] = Function[client, AppendTo[actions, {"Close", client}]; Null];
        KirillBelov`WebSocket`Private`serverReceived[handler, <|
            "SourceSocket" -> "closing",
            "DataByteArray" -> KirillBelov`WebSocket`Private`encodeFrame[ByteArray[{3, 232}], 8, True]
        |>];
        {actions, handler["Connections"]["Length"]}
    ],
    {{{"Send", "closing", ByteArray[{136, 2, 3, 232}]}, {"Close", "closing"}}, 0},
    TestID -> "server writes close acknowledgement before closing transport"
];


TestReport[Join[Values[report["TestResults"]], {loopback, closeAdapter}]]
