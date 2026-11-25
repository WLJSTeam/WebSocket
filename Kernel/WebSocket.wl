(* ::Package:: *)

(* ::Program:: *)
(*+-----------------------------------------------------------------------------------------+*)
(*|                           WEBSOCKET HANDLER                                             |*)
(*|                                                                                         |*)
(*|                   packet: SourceSocket + DataByteArray                                  |*)
(*|                                    |                                                    |*)
(*|                          <Closed / Error event?>                                        |*)
(*|                        yes /                 \ no                                       |*)
(*|              [clear connection state]   [append bytes to Buffer]                        |*)
(*|                        |                         |                                      |*)
(*|                   {return Null}          <connection established?>                      |*)
(*|                                        no /                  \ yes                      |*)
(*|                            <Handshake enabled?>               |                         |*)
(*|                          yes /              \ no              |                         |*)
(*|                 <complete HTTP header?>  [register client]    |                         |*)
(*|                  no /          \ yes            |             |                         |*)
(*|      [save bytes; wait]   [validate upgrade]     |             |                        |*)
(*|                                |                |             |                         |*)
(*|                        <valid request?>         |             |                         |*)
(*|                       no /          \ yes       |             |                         |*)
(*|                {return $Failed}  [queue 101; register client] |                         |*)
(*|                                       \         |            /                          |*)
(*|                                        [FRAME LOOP] <--------+                          |*)
(*|                                              |                                          |*)
(*|                           <valid header / enough frame bytes?>                          |*)
(*|                      invalid /          | incomplete       \ complete                   |*)
(*|                [queue Close 1002]  [save bytes in Buffer]   [decode / unmask]           |*)
(*|                [clear state; stop]      [leave loop]               |                    |*)
(*|                                                               <opcode>                  |*)
(*|                          +----------------+----------------+------+                     |*)
(*|                          |                |                |                            |*)
(*|                    [Close / 8]       [Ping / 9]        [Pong / 10]                      |*)
(*|                          |                |                |                            |*)
(*|                  [validate payload]  [queue Pong with    [ignore]                       |*)
(*|                  [queue Close reply]  same payload]        |                            |*)
(*|                  [clear state; stop]      |                |                            |*)
(*|                                           +--------> [next frame]                       |*)
(*|                                                                                         |*)
(*|                    [Text / 1]  [Binary / 2]  [Continuation / 0]                         |*)
(*|                          \          |          /                                        |*)
(*|                           [check fragment sequence]                                     |*)
(*|                                      |                                                  |*)
(*|                       [join payload with saved Fragments]                               |*)
(*|                                      |                                                  |*)
(*|                                    <FIN?>                                               |*)
(*|                             no /           \ yes                                        |*)
(*|                   [save opcode + bytes]  [clear Fragments]                              |*)
(*|                             |                    |                                      |*)
(*|                        [next frame]         <message opcode>                            |*)
(*|                                       text /            \ binary                        |*)
(*|                             [validate UTF-8; String]   [ByteArray]                      |*)
(*|                                           \            /                                |*)
(*|                                            [Deserializer]                               |*)
(*|                                                  |                                      |*)
(*|                                         <select message handler>                        |*)
(*|                                   matching rule /        \ no match                     |*)
(*|                                        [callback]   [DefaultMessageHandler]             |*)
(*|                                              \         /                                |*)
(*|                                                <result>                                 |*)
(*|                           +-----------------------+----------------------+              |*)
(*|                           |                       |                      |              |*)
(*|                         Null              String / ByteArray        other expression    |*)
(*|                           |                       |                      |              |*)
(*|                     [no response]                 |                 [Serializer]        |*)
(*|                           |                       |                      |              |*)
(*|                      [next frame]                 +----------+-----------+              |*)
(*|                                                              |                          |*)
(*|                                                    <serialized result>                  |*)
(*|                                       +----------------------+------------------+       |*)
(*|                                       |                      |                  |       |*)
(*|                                     String                ByteArray            Null     |*)
(*|                                       |                      |                  |       |*)
(*|                                [text frame / 1]      [binary frame / 2]   [no response] |*)
(*|                                       \                      /                  |       |*)
(*|                                        [queue encoded frame]                    |       |*)
(*|                                                   |                             |       |*)
(*|                                                   +----------> [next frame] <---+       |*)
(*|                                                                                         |*)
(*|   FRAME LOOP: consume all complete frames from this chunk; keep remaining bytes.        |*)
(*|   RETURN: queued HTTP/frame responses joined into one ByteArray, or Null.               |*)
(*|                                                                                         |*)
(*|   TRANSPORT BOUNDARY                                                                    |*)
(*|   handler[packet] -> response bytes -> caller / CSockets writes to transport.           |*)
(*|   On Close/error: write queued Close first, then close the transport.                   |*)
(*|   WebSocketSend[client, expr, opts] -> encode -> SendFunction[client, bytes].           |*)
(*|   Send options: Serializer, Masking, SendFunction; no client-to-handler lookup.         |*)
(*|                                                                                         |*)
(*|   STATE AND PROTOCOL NOTES                                                              |*)
(*|   Buffer stores incomplete stream bytes; Fragments stores an unfinished message.        |*)
(*|   Connections, Buffer and Fragments belong to each handler; no shared registry.         |*)
(*|   Ping/Pong may appear between fragments without changing the message opcode.           |*)
(*|   Invalid framing/close payload -> Close 1002; invalid UTF-8 -> Close 1007.             |*)
(*|   Server role: masked input, unmasked output. Client role: the reverse.                 |*)
(*|   Handshake -> False skips the upgrade step for synthetic/pre-upgraded streams.         |*)
(*|   WebSocketPacketQ[handler, packet] checks that handler's handshake/buffer state.       |*)
(*+-----------------------------------------------------------------------------------------+*)


BeginPackage["KirillBelov`WebSocket`", {"WLJS`Objects`"}];


WebSocketPacketQ::usage =
"WebSocketPacketQ[packet] recognizes an opening WebSocket request. WebSocketPacketQ[handler, packet] also checks the handler's connection and input-buffer state.";


WebSocketPacketLength::usage =
"WebSocketPacketLength[packet] returns the first frame length, or the next required header length for incomplete data.";


WebSocketHandler::usage =
"WebSocketHandler[opts][packet] consumes stream bytes and returns encoded responses or Null, independently of sockets.";


WebSocketFrame::usage =
"WebSocketFrame[payload] encodes a String as a text frame or a ByteArray as a binary frame.";


WebSocketSend::usage =
"WebSocketSend[client, expression, opts] serializes and sends a frame using explicit Serializer, Masking and SendFunction options.";


WebSocketServerCreate::usage =
"WebSocketServerCreate[host, port, name, messageHandlers] creates a CSockets server adapter.";


WebSocketConnect::usage =
"WebSocketConnect[address] opens a ws:// client connection.";


WebSocketConnection::usage =
"WebSocketConnection[...] represents a client connection.";


Begin["`Private`"];


$guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";


CreateType[WebSocketHandler, init, {
    "MessageHandler" -> <||>,
    "DefaultMessageHandler" -> Function[Null],
    "Serializer" -> ToString,
    "Deserializer" -> Identity,
    "SendFunction" -> BinaryWrite,
    "CloseFunction" -> Close,
    "Role" -> "Server",
    "Handshake" -> True,
    "Connections", "Buffer", "Fragments"
}];


WebSocketHandler /: init[handler_WebSocketHandler] := (
    handler["Connections"] = CreateDataStructure["HashSet"];
    handler["Buffer"] = CreateDataStructure["HashTable"];
    handler["Fragments"] = CreateDataStructure["HashTable"];
);


packetQ[packet_Association] :=
KeyExistsQ[packet, "SourceSocket"] && ByteArrayQ[Lookup[packet, "DataByteArray"]];


WebSocketPacketQ[packet_Association] :=
packetQ[packet] && Take[Normal[packet["DataByteArray"]], UpTo[4]] === {71, 69, 84, 32};


WebSocketPacketQ[handler_WebSocketHandler, packet_Association] :=
packetQ[packet] && (handler["Connections"]["MemberQ", packet["SourceSocket"]] ||
    handler["Buffer"]["KeyExistsQ", packet["SourceSocket"]] || WebSocketPacketQ[packet]);


WebSocketPacketQ[_WebSocketHandler, _] :=
False;


WebSocketPacketQ[_] :=
False;


WebSocketPacketLength[packet_Association?packetQ] :=
Module[{data = Normal[packet["DataByteArray"]], end},
    If[Take[data, UpTo[4]] === {71, 69, 84, 32},
        end = SequencePosition[data, {13, 10, 13, 10}, 1];
        Return[If[end === {}, Length[data] + 1, end[[1, 2]]]]
    ];
    frameLength[data]
];


frameLength[data_List] :=
Module[{size = Length[data], marker, header, payload},
    If[size < 2, Return[2]];
    marker = BitAnd[data[[2]], 127];
    header = Switch[marker, 126, 4, 127, 10, _, 2];
    If[size < header, Return[header]];
    payload = If[marker < 126, marker, FromDigits[Take[data, {3, header}], 256]];
    header + If[BitAnd[data[[2]], 128] > 0, 4, 0] + payload
];


Options[WebSocketFrame] = {"Masking" -> False};


WebSocketFrame[text_String, opts: OptionsPattern[]] :=
encodeFrame[StringToByteArray[text, "UTF-8"], 1, OptionValue["Masking"]];


WebSocketFrame[bytes_ByteArray, opts: OptionsPattern[]] :=
encodeFrame[bytes, 2, OptionValue["Masking"]];


encodeFrame[bytes_ByteArray, opcode_Integer, masking: True | False, fin: True | False: True] :=
Module[{length = Length[bytes], header, key, payload = Normal[bytes]},
    header = Join[{If[fin, 128, 0] + opcode}, Which[
        length < 126, {length},
        length < 2^16, Join[{126}, IntegerDigits[length, 256, 2]],
        True, Join[{127}, IntegerDigits[length, 256, 8]]
    ]];
    If[masking,
        header[[2]] += 128;
        key = RandomInteger[{0, 255}, 4];
        header = Join[header, key];
        payload = maskBytes[payload, key]
    ];
    ByteArray[Join[header, payload]]
];


maskBytes[bytes_List, key_List] :=
MapIndexed[BitXor[#1, key[[Mod[First[#2] - 1, 4] + 1]]]&, bytes];


(* Incomplete stream data is buffered here, rather than in a transport accumulator:
   CSockets fixes ExpectedLength after the first chunk, which may contain only one header byte. *)
(handler_WebSocketHandler)[packet_Association] :=
Module[{client, data, stored, responses = {}, response, length, frame, event},
    client = Lookup[packet, "SourceSocket", Missing["SourceSocket"]];
    If[MissingQ[client], Return[$Failed]];
    event = Lookup[packet, "Event", "Received"];
    If[MemberQ[{"Closed", "Error"}, event], forgetClient[handler, client]; Return[Null]];
    If[!packetQ[packet], Return[$Failed]];
    stored = handler["Buffer"]["Lookup", client];
    data = Join[If[MissingQ[stored], {}, Normal[stored]], Normal[packet["DataByteArray"]]];
    handler["Buffer"]["KeyDrop", client];
    If[!handler["Connections"]["MemberQ", client],
        If[TrueQ[handler["Handshake"]],
            length = SequencePosition[data, {13, 10, 13, 10}, 1];
            If[length === {}, handler["Buffer"]["Insert", client -> ByteArray[data]]; Return[Null]];
            length = length[[1, 2]];
            response = handshake[ByteArray[Take[data, length]]];
            If[response === $Failed, Return[$Failed]];
            AppendTo[responses, response];
            data = Drop[data, length]
        ];
        handler["Connections"]["Insert", client]
    ];
    While[Length[data] > 0,
        If[!validHeaderQ[data, handler["Role"] === "Server"],
            AppendTo[responses, protocolError[handler, client, 1002]];
            data = {};
            Break[]
        ];
        length = frameLength[data];
        If[Length[data] < length, Break[]];
        frame = decodeFrame[Take[data, length], handler["Role"] === "Server"];
        data = Drop[data, length];
        response = If[frame === $Failed, protocolError[handler, client, 1002], processFrame[handler, client, frame]];
        If[ByteArrayQ[response], AppendTo[responses, response]];
        If[!handler["Connections"]["MemberQ", client], data = {}; Break[]]
    ];
    If[Length[data] > 0, handler["Buffer"]["Insert", client -> ByteArray[data]]];
    If[responses === {}, Null, Apply[Join, responses]]
];


handshake[bytes_ByteArray] :=
Module[{lines, headers, key, decoded},
    lines = StringSplit[ByteArrayToString[bytes], "\r\n"];
    If[!StringMatchQ[First[lines], "GET " ~~ Except[" "].. ~~ " HTTP/1.1"], Return[$Failed]];
    headers = parseHeaders[Rest[lines]];
    key = Lookup[headers, "sec-websocket-key", ""];
    decoded = Quiet[Check[BaseDecode[key], $Failed]];
    If[Lookup[headers, "host", ""] === "" ||
        ToLowerCase[Lookup[headers, "upgrade", ""]] =!= "websocket" ||
        !MemberQ[StringTrim /@ StringSplit[ToLowerCase[Lookup[headers, "connection", ""]], ","], "upgrade"] ||
        Lookup[headers, "sec-websocket-version", ""] =!= "13" ||
        !ByteArrayQ[decoded] || Length[decoded] =!= 16, Return[$Failed]];
    StringToByteArray["HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " <>
        acceptKey[key] <> "\r\n\r\n"]
];


parseHeaders[lines_List] :=
Association @ Cases[lines, line_String /; StringContainsQ[line, ":"] :>
    With[{parts = StringSplit[line, ":", 2]}, ToLowerCase[StringTrim[First[parts]]] -> StringTrim[Last[parts]]]];


acceptKey[key_String] :=
BaseEncode[Hash[key <> $guid, "SHA1", "ByteArray"], "Base64"];


validHeaderQ[data_List, expectedMask: True | False] :=
Module[{opcode, marker, header, length},
    If[Length[data] < 2, Return[True]];
    opcode = BitAnd[data[[1]], 15];
    marker = BitAnd[data[[2]], 127];
    If[BitAnd[data[[1]], 112] =!= 0 || !MemberQ[{0, 1, 2, 8, 9, 10}, opcode] ||
        (BitAnd[data[[2]], 128] > 0) =!= expectedMask ||
        (opcode >= 8 && (marker > 125 || data[[1]] < 128)), Return[False]];
    header = Switch[marker, 126, 4, 127, 10, _, 2];
    If[Length[data] < header, Return[True]];
    length = If[marker < 126, marker, FromDigits[Take[data, {3, header}], 256]];
    length < 2^63 && !(marker === 126 && length < 126) && !(marker === 127 && length < 2^16)
];


decodeFrame[data_List, expectedMask: True | False] :=
Module[{opcode, marker, header, masked, key, payload},
    If[!validHeaderQ[data, expectedMask], Return[$Failed]];
    opcode = BitAnd[data[[1]], 15];
    marker = BitAnd[data[[2]], 127];
    masked = BitAnd[data[[2]], 128] > 0;
    header = Switch[marker, 126, 4, 127, 10, _, 2];
    key = If[masked, Take[data, {header + 1, header + 4}], {}];
    payload = Drop[data, header + If[masked, 4, 0]];
    If[masked, payload = maskBytes[payload, key]];
    <|"Fin" -> (data[[1]] >= 128), "Opcode" -> opcode, "Payload" -> ByteArray[payload]|>
];


processFrame[handler_WebSocketHandler, client_, frame_Association] :=
Module[{opcode = frame["Opcode"], payload = frame["Payload"], fragment, result, callback, text, code},
    fragment = handler["Fragments"]["Lookup", client];
    Switch[opcode,
        8,
            If[Length[payload] === 1, Return[protocolError[handler, client, 1002]]];
            If[Length[payload] >= 2,
                code = FromDigits[Take[Normal[payload], 2], 256];
                If[!validCloseCodeQ[code], Return[protocolError[handler, client, 1002]]];
                If[utf8[ByteArray[Drop[Normal[payload], 2]]] === $Failed, Return[protocolError[handler, client, 1007]]]
            ];
            forgetClient[handler, client];
            Return[encodeFrame[payload, 8, handler["Role"] === "Client"]],
        9, Return[encodeFrame[payload, 10, handler["Role"] === "Client"]],
        10, Return[Null],
        0,
            If[MissingQ[fragment], Return[protocolError[handler, client, 1002]]];
            opcode = fragment["Opcode"];
            payload = Join[fragment["Payload"], payload],
        _,
            If[!MissingQ[fragment], Return[protocolError[handler, client, 1002]]]
    ];
    If[!frame["Fin"],
        handler["Fragments"]["Insert", client -> <|"Opcode" -> opcode, "Payload" -> payload|>];
        Return[Null]
    ];
    handler["Fragments"]["KeyDrop", client];
    text = If[opcode === 1, utf8[payload], payload];
    If[text === $Failed, Return[protocolError[handler, client, 1007]]];
    text = handler["Deserializer"][text];
    callback = handler["MessageHandler"];
    If[AssociationQ[callback],
        callback = Last[SelectFirst[Values[callback], TrueQ[First[#][client, text]]&, {handler["DefaultMessageHandler"]}]]
    ];
    result = callback[client, text];
    serializeFrame[result, handler["Serializer"], handler["Role"] === "Client"]
];


utf8[bytes_ByteArray] :=
Module[{text = Quiet[Check[ByteArrayToString[bytes, "UTF-8"], $Failed]]},
    If[StringQ[text] && StringToByteArray[text, "UTF-8"] === bytes, text, $Failed]
];


validCloseCodeQ[code_Integer] :=
MemberQ[{1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014}, code] || 3000 <= code <= 4999;


serializeFrame[expression_, serializer_, masking: True | False] :=
Module[{result = expression},
    If[result === Null, Return[Null]];
    If[!MatchQ[result, _String | _ByteArray], result = serializer[result]];
    If[result === Null, Return[Null]];
    If[!MatchQ[result, _String | _ByteArray], Return[$Failed]];
    WebSocketFrame[result, "Masking" -> masking]
];


forgetClient[handler_WebSocketHandler, client_] := (
    handler["Connections"]["Remove", client];
    handler["Buffer"]["KeyDrop", client];
    handler["Fragments"]["KeyDrop", client];
);


protocolError[handler_WebSocketHandler, client_, code_Integer] := (
    forgetClient[handler, client];
    encodeFrame[ByteArray[IntegerDigits[code, 256, 2]], 8, handler["Role"] === "Client"]
);


Options[WebSocketSend] = {
    "Serializer" -> ToString,
    "Masking" -> False,
    "SendFunction" -> BinaryWrite
};


WebSocketSend[client_, expression_, OptionsPattern[]] :=
Module[{frame, masking = OptionValue["Masking"]},
    If[!BooleanQ[masking], Return[$Failed]];
    frame = serializeFrame[expression, OptionValue["Serializer"], masking];
    If[ByteArrayQ[frame], OptionValue["SendFunction"][client, frame], frame]
];


(* CSockets is loaded only by the optional transport adapters. *)
Options[WebSocketServerCreate] = Options[WebSocketHandler];


WebSocketServerCreate[host: _String: "localhost", port_Integer?Positive,
    name: _String: "WebSocket", callbacks_Association, opts: OptionsPattern[]] :=
Module[{socket, transport, handler, listener},
    Needs["WLJS`CSockets`"];
    socket = WLJS`CSockets`CSocketOpen[host, port];
    If[socket === $Failed, Return[$Failed]];
    handler = WebSocketHandler[opts];
    handler["MessageHandler"] = callbacks;
    transport = WLJS`CSockets`CSocketHandler[
        "Received" -> Function[serverReceived[handler, #]],
        "Closed" -> Function[handler[#]],
        "Error" -> Function[handler[#]]
    ];
    listener = SocketListen[socket, transport];
    handler["Socket"] = socket;
    handler["Listener"] = listener;
    handler["TransportHandler"] = transport;
    handler
];


serverReceived[handler_WebSocketHandler, packet_Association] :=
Module[{response = handler[packet], client = packet["SourceSocket"]},
    If[response === $Failed,
        forgetClient[handler, client];
        handler["CloseFunction"][client];
        Return[Null]
    ];
    If[ByteArrayQ[response] && !handler["Connections"]["MemberQ", client],
        handler["SendFunction"][client, response];
        handler["CloseFunction"][client];
        Null,
        response
    ]
];


WebSocketHandler /: Close[handler_WebSocketHandler] := (
    Scan[Function[client,
        forgetClient[handler, client];
        handler["CloseFunction"][client]
    ], Union[handler["Connections"]["Elements"], handler["Buffer"]["Keys"], handler["Fragments"]["Keys"]]];
    If[MatchQ[handler["Listener"], _SocketListenerObject], DeleteObject[handler["Listener"]]];
    If[MatchQ[handler["Socket"], _WLJS`CSockets`CSocketObject], Close[handler["Socket"]]];
);


CreateType[WebSocketConnection, {"Address", "Socket", "Handler", "Messages", "Serializer" -> ToString, "Deserializer" -> Identity}];


Options[WebSocketConnect] = {"Headers" -> <||>, "Serializer" -> ToString, "Deserializer" -> Identity, "Timeout" -> 5};


WebSocketConnect[address_String, OptionsPattern[]] :=
Module[{url = URLParse[address], socket, host, port, path, key, headers, bytes = {}, chunk, end, response, handler, connection, deadline},
    If[url["Scheme"] =!= "ws", Return[$Failed]];
    Needs["WLJS`CSockets`"];
    host = url["Domain"];
    port = Replace[url["Port"], None -> 80];
    path = URLBuild[<|"Path" -> url["Path"], "Query" -> url["Query"]|>];
    If[!StringStartsQ[path, "/"], path = "/" <> path];
    key = BaseEncode[ByteArray[RandomInteger[{0, 255}, 16]], "Base64"];
    headers = OptionValue["Headers"];
    If[!AssociationQ[headers] || !AllTrue[Normal[headers], MatchQ[#, _String -> _String]&], Return[$Failed]];
    socket = WLJS`CSockets`CSocketConnect[host, port];
    If[socket === $Failed, Return[$Failed]];
    WriteString[socket, "GET " <> path <> " HTTP/1.1\r\nHost: " <> host <> ":" <> ToString[port] <>
        "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " <> key <>
        "\r\nSec-WebSocket-Version: 13\r\n" <> StringJoin[KeyValueMap[#1 <> ": " <> #2 <> "\r\n"&, headers]] <> "\r\n"];
    deadline = AbsoluteTime[] + OptionValue["Timeout"];
    While[AbsoluteTime[] < deadline,
        If[TrueQ[SocketReadyQ[socket, 0.01]],
            chunk = SocketReadMessage[socket];
            If[!ByteArrayQ[chunk] || Length[chunk] === 0, Break[]];
            bytes = Join[bytes, Normal[chunk]];
            end = SequencePosition[bytes, {13, 10, 13, 10}, 1];
            If[end =!= {}, Break[]]
        ]
    ];
    If[!ListQ[end] || end === {}, Close[socket]; Return[$Failed]];
    end = end[[1, 2]];
    response = StringSplit[ByteArrayToString[ByteArray[Take[bytes, end]]], "\r\n"];
    headers = parseHeaders[Rest[response]];
    If[!StringStartsQ[First[response], "HTTP/1.1 101 "] ||
        Lookup[headers, "sec-websocket-accept", ""] =!= acceptKey[key] ||
        ToLowerCase[Lookup[headers, "upgrade", ""]] =!= "websocket" ||
        !MemberQ[StringTrim /@ StringSplit[ToLowerCase[Lookup[headers, "connection", ""]], ","], "upgrade"],
        Close[socket]; Return[$Failed]
    ];
    handler = WebSocketHandler["Role" -> "Client", "Handshake" -> False,
        "Serializer" -> OptionValue["Serializer"], "Deserializer" -> OptionValue["Deserializer"]];
    connection = WebSocketConnection["Address" -> address, "Socket" -> socket, "Handler" -> handler,
        "Messages" -> CreateDataStructure["Queue"],
        "Serializer" -> OptionValue["Serializer"], "Deserializer" -> OptionValue["Deserializer"]];
    handler["DefaultMessageHandler"] = Function[{client, message}, connection["Messages"]["Push", message]; Null];
    handler["Connections"]["Insert", socket];
    If[Length[bytes] > end, consumeClient[connection, ByteArray[Drop[bytes, end]]]];
    connection
];


consumeClient[connection_WebSocketConnection, bytes_ByteArray] :=
Module[{handler = connection["Handler"], response, socket = connection["Socket"]},
    handler["Deserializer"] = connection["Deserializer"];
    response = handler[<|"SourceSocket" -> socket, "DataByteArray" -> bytes|>];
    If[ByteArrayQ[response], BinaryWrite[socket, response]];
    If[!handler["Connections"]["MemberQ", socket], Close[socket]];
];


WebSocketConnection /: WebSocketSend[connection_WebSocketConnection, expression_, opts: OptionsPattern[WebSocketSend]] :=
WebSocketSend[connection["Socket"], expression, Sequence @@ Normal[Join[
    <|
        "Serializer" -> connection["Serializer"],
        "Masking" -> True,
        "SendFunction" -> connection["Handler"]["SendFunction"]
    |>,
    <|opts|>
]]];


WebSocketConnection /: SocketReadyQ[connection_WebSocketConnection, timeout: (_Integer | _Real): 0] :=
connection["Messages"]["Length"] > 0 || SocketReadyQ[connection["Socket"], timeout];


WebSocketConnection /: SocketReadMessage[connection_WebSocketConnection] :=
Module[{bytes},
    While[connection["Messages"]["Length"] === 0 && TrueQ[SocketReadyQ[connection["Socket"]]],
        bytes = SocketReadMessage[connection["Socket"]];
        If[!ByteArrayQ[bytes] || Length[bytes] === 0, Break[]];
        consumeClient[connection, bytes]
    ];
    If[connection["Messages"]["Length"] > 0, connection["Messages"]["Pop"], $Failed]
];


WebSocketConnection /: Close[connection_WebSocketConnection] := (
    forgetClient[connection["Handler"], connection["Socket"]];
    Close[connection["Socket"]]
);


End[];


EndPackage[];
