(* ::Package:: *)

packet[bytes_ByteArray, client_: "test"] :=
<|"SourceSocket" -> client, "DataByteArray" -> bytes|>;


echoHandler[opts___] :=
WebSocketHandler["Handshake" -> False, "DefaultMessageHandler" -> Function[{client, message}, message], opts];


masked[payload_] :=
WebSocketFrame[payload, "Masking" -> True];


raw[payload_ByteArray, opcode_Integer, fin_: True] :=
KirillBelov`WebSocket`Private`encodeFrame[payload, opcode, True, fin];


request = StringToByteArray["GET /chat HTTP/1.1\r\nHost: localhost\r\nupgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Version: 13\r\nsec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"];


tests = {
    VerificationTest[MemberQ[$Packages, "WLJS`CSockets`"], False, TestID -> "core loads without CSockets"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[ByteArray[{193, 255}]]]],
        ByteArray[{136, 2, 3, 234}], TestID -> "reject reserved bits before waiting for payload"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[ByteArray[{137, 254}]]]],
        ByteArray[{136, 2, 3, 234}], TestID -> "reject oversized control header immediately"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[ByteArray[{129, 254, 0, 1}]]]],
        ByteArray[{136, 2, 3, 234}], TestID -> "reject nonminimal extended length"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[ByteArray[{129, 255, 128, 0, 0, 0, 0, 0, 0, 0}]]]],
        ByteArray[{136, 2, 3, 234}], TestID -> "reject 64bit length high bit"],
    VerificationTest[Module[{h = WebSocketHandler["DefaultMessageHandler" -> Function[{client, message}, message]], result},
        result = h[packet[Join[request, masked["first"]]]];
        Take[Normal[result], -7]], Normal[WebSocketFrame["first"]], TestID -> "upgrade and first frame in same chunk"],
    VerificationTest[Module[{h = WebSocketHandler[], closed = {}},
        h["CloseFunction"] = Function[client, AppendTo[closed, client]; Null];
        h[packet[ByteArray[{71}], "pending"]];
        Close[h];
        {closed, h["Buffer"]["Length"]}], {{"pending"}, 0}, TestID -> "closing handler clears incomplete handshake"],
    VerificationTest[Module[{h = echoHandler[], seen = {}},
        h["Deserializer"] = Function[message, AppendTo[seen, Head[message]]; message];
        h[packet[Join[masked["text"], masked[ByteArray[{255}]]]]];
        seen], {String, ByteArray}, TestID -> "deserializer receives message type"],
    VerificationTest[Normal[WebSocketFrame["Hello"]], {129, 5, 72, 101, 108, 108, 111}, TestID -> "RFC text encoding"],
    VerificationTest[Normal[WebSocketFrame[ByteArray[{0, 255}]]], {130, 2, 0, 255}, TestID -> "binary encoding"],
    VerificationTest[Normal[WebSocketFrame[""]], {129, 0}, TestID -> "empty text"],
    VerificationTest[Normal[WebSocketFrame[ByteArray[{}]]], {130, 0}, TestID -> "empty binary"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[masked["Привет 🌍"]]]], WebSocketFrame["Привет 🌍"], TestID -> "UTF8 echo"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[masked[ByteArray[{0, 128, 255}]]]]], WebSocketFrame[ByteArray[{0, 128, 255}]], TestID -> "binary echo preserves bytes"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[masked[""]]]], WebSocketFrame[""], TestID -> "empty text roundtrip"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[masked[ByteArray[{}]]]]], WebSocketFrame[ByteArray[{}]], TestID -> "empty binary roundtrip"],
    VerificationTest[Module[{h = WebSocketHandler[]}, ByteArrayToString[h[packet[request]]]],
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n", TestID -> "RFC handshake"],
    VerificationTest[Module[{h = WebSocketHandler[], responses}, responses = h[packet[ByteArray[{#}]]]& /@ Normal[request];
        Count[responses, _ByteArray]], 1, TestID -> "bytewise handshake"],
    VerificationTest[Module[{h = WebSocketHandler[]}, h[packet[StringToByteArray["GET / HTTP/1.1\r\nUpgrade: websocket\r\n\r\n"]]]], $Failed, TestID -> "reject missing handshake fields"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[Join[masked["a"], masked[ByteArray[{9}]]]]]],
        Join[WebSocketFrame["a"], WebSocketFrame[ByteArray[{9}]]], TestID -> "coalesced text binary"],
    VerificationTest[Module[{h = echoHandler[], input = masked[StringRepeat["x", 126]], responses},
        responses = h[packet[ByteArray[{#}]]]& /@ Normal[input]; Last[responses]], WebSocketFrame[StringRepeat["x", 126]], TestID -> "bytewise extended header and payload"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[Join[raw[StringToByteArray["hel"], 1, False], raw[StringToByteArray["lo"], 0]]]]],
        WebSocketFrame["hello"], TestID -> "text continuation retains opcode"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[Join[raw[ByteArray[{255}], 2, False], raw[ByteArray[{128}], 0]]]]],
        WebSocketFrame[ByteArray[{255, 128}]], TestID -> "binary continuation"],
    VerificationTest[Module[{h = echoHandler[], bytes = Normal[StringToByteArray["€"]]},
        h[packet[Join[raw[ByteArray[Take[bytes, 1]], 1, False], raw[ByteArray[Drop[bytes, 1]], 0]]]]], WebSocketFrame["€"], TestID -> "UTF8 split between fragments"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[Join[raw[StringToByteArray["a"], 1, False], raw[ByteArray[{7}], 9], raw[StringToByteArray["b"], 0]]]]],
        Join[ByteArray[{138, 1, 7}], WebSocketFrame["ab"]], TestID -> "ping between fragments"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[raw[ByteArray[{}], 10]]]], Null, TestID -> "ignore pong"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[raw[ByteArray[{3, 232}], 8]]]], ByteArray[{136, 2, 3, 232}], TestID -> "close acknowledgement"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[raw[ByteArray[{}], 0]]]], ByteArray[{136, 2, 3, 234}], TestID -> "orphan continuation protocol error"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[WebSocketFrame["unmasked"]]]], ByteArray[{136, 2, 3, 234}], TestID -> "reject unmasked client data"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[raw[ByteArray[{255}], 1]]]], ByteArray[{136, 2, 3, 239}], TestID -> "reject invalid UTF8"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[raw[ByteArray[{1}], 8]]]], ByteArray[{136, 2, 3, 234}], TestID -> "reject short close code"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[raw[ByteArray[{3, 237}], 8]]]], ByteArray[{136, 2, 3, 234}], TestID -> "reject reserved close code"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[raw[ByteArray[{1}], 9, False]]]], ByteArray[{136, 2, 3, 234}], TestID -> "reject fragmented control"],
    VerificationTest[Module[{h = echoHandler[], input = masked["test"]},
        h[packet[ByteArray[Take[Normal[input], 3]], "one"]];
        h[packet[masked["other"], "two"]];
        h[packet[ByteArray[Drop[Normal[input], 3]], "one"]]], WebSocketFrame["test"], TestID -> "connection buffer isolation"],
    VerificationTest[Module[{h = echoHandler[]}, h[packet[raw[ByteArray[{1}], 2, False]]];
        h[<|"SourceSocket" -> "test", "Event" -> "Closed"|>];
        {h["Connections"]["Length"], h["Buffer"]["Length"], h["Fragments"]["Length"]}], {0, 0, 0}, TestID -> "disconnect clears state"],
    VerificationTest[Module[{h = WebSocketHandler["Handshake" -> False, "DefaultMessageHandler" -> Function[42], "Serializer" -> Function[ByteArray[{42}]]]},
        h[packet[masked["x"]]]], WebSocketFrame[ByteArray[{42}]], TestID -> "serializer chooses binary opcode"],
    VerificationTest[Module[{h = WebSocketHandler["Handshake" -> False]}, h[packet[masked["x"]]]], Null, TestID -> "default callback sends nothing"],
    VerificationTest[Module[{sent = {}},
        WebSocketSend["manual", ByteArray[{255}],
            "SendFunction" -> Function[{client, bytes}, AppendTo[sent, {client, bytes}]; Null]];
        sent], {{"manual", WebSocketFrame[ByteArray[{255}]]}}, TestID -> "explicit injected sender"],
    VerificationTest[Module[{h1 = WebSocketHandler[], h2 = WebSocketHandler[]},
        h1[packet[request, "same"]];
        {WebSocketPacketQ[h1, packet[masked["data"], "same"]], WebSocketPacketQ[h2, packet[masked["data"], "same"]]}],
        {True, False}, TestID -> "handshake state belongs to one handler"],
    VerificationTest[Module[{h1 = echoHandler[], h2 = echoHandler[], a = Normal[masked["first"]], b = Normal[masked["second"]]},
        h1[packet[ByteArray[Take[a, 3]], "same"]];
        h2[packet[ByteArray[Take[b, 4]], "same"]];
        {h1[packet[ByteArray[Drop[a, 3]], "same"]], h2[packet[ByteArray[Drop[b, 4]], "same"]]}],
        {WebSocketFrame["first"], WebSocketFrame["second"]}, TestID -> "same client identifier has independent buffers"],
    VerificationTest[Module[{h1 = echoHandler[], h2 = echoHandler[]},
        h1[packet[raw[StringToByteArray["a"], 1, False], "same"]];
        h2[packet[raw[ByteArray[{255}], 2, False], "same"]];
        h1[<|"Event" -> "Closed", "SourceSocket" -> "same"|>];
        {WebSocketPacketQ[h1, packet[masked["x"], "same"]], h2[packet[raw[ByteArray[{128}], 0], "same"]]}],
        {False, WebSocketFrame[ByteArray[{255, 128}]]}, TestID -> "closing one handler preserves another handler fragments"],
    VerificationTest[Module[{h1 = WebSocketHandler[], h2 = WebSocketHandler[]},
        h1[packet[ByteArray[{71}], "same"]];
        {WebSocketPacketQ[h1, packet[ByteArray[{69}], "same"]], WebSocketPacketQ[h2, packet[ByteArray[{69}], "same"]]}],
        {True, False}, TestID -> "pending handshake routing uses handler buffer"],
    VerificationTest[Module[{sent = {}},
        WebSocketSend["client", 42, "Serializer" -> Function[ByteArray[{42}]],
            "SendFunction" -> Function[{client, bytes}, AppendTo[sent, bytes]; Null]];
        sent], {WebSocketFrame[ByteArray[{42}]]}, TestID -> "send serializer chooses binary frame"],
    VerificationTest[Module[{sent = {}},
        WebSocketSend["client", 42, "Serializer" -> Function["answer"],
            "SendFunction" -> Function[{client, bytes}, AppendTo[sent, bytes]; Null]];
        sent], {WebSocketFrame["answer"]}, TestID -> "send serializer chooses text frame"],
    VerificationTest[Module[{sent = {}},
        WebSocketSend["client", "masked", "Masking" -> True,
            "SendFunction" -> Function[{client, bytes}, AppendTo[sent, bytes]; Null]];
        KirillBelov`WebSocket`Private`decodeFrame[Normal[First[sent]], True]["Payload"]],
        StringToByteArray["masked"], TestID -> "explicit client masking option"],
    VerificationTest[Module[{sent = {}},
        {WebSocketSend["client", Null, "SendFunction" -> Function[{client, bytes}, AppendTo[sent, bytes]]], sent}],
        {Null, {}}, TestID -> "send Null does not invoke transport"],
    VerificationTest[Module[{sent = {}},
        {WebSocketSend["client", 42, "Serializer" -> Function[Null],
            "SendFunction" -> Function[{client, bytes}, AppendTo[sent, bytes]]], sent}],
        {Null, {}}, TestID -> "serializer can suppress send"],
    VerificationTest[Module[{sent = {}},
        {WebSocketSend["client", 42, "Serializer" -> Identity,
            "SendFunction" -> Function[{client, bytes}, AppendTo[sent, bytes]]], sent}],
        {$Failed, {}}, TestID -> "invalid serialized result does not invoke transport"],
    VerificationTest[WebSocketSend["client", "data", "Masking" -> Automatic], $Failed, TestID -> "masking must be explicit boolean"],
    VerificationTest[Module[{h = echoHandler[], connection, sent = {}, frame},
        h["SendFunction"] = Function[{client, bytes}, AppendTo[sent, bytes]; Null];
        connection = WebSocketConnection["Socket" -> "client", "Handler" -> h, "Serializer" -> Function[ByteArray[{42}]]];
        WebSocketSend[connection, 42];
        frame = First[sent];
        {BitAnd[frame[[2]], 128], KirillBelov`WebSocket`Private`decodeFrame[Normal[frame], True]["Payload"]}],
        {128, ByteArray[{42}]}, TestID -> "connection forwards serializer and client masking defaults"],
    VerificationTest[Module[{h = echoHandler[], connection, sent = {}},
        h["SendFunction"] = Function[$Failed];
        connection = WebSocketConnection["Socket" -> "client", "Handler" -> h, "Serializer" -> Identity];
        WebSocketSend[connection, 42, "Serializer" -> Function["override"], "Masking" -> False,
            "SendFunction" -> Function[{client, bytes}, AppendTo[sent, bytes]; Null]];
        sent], {WebSocketFrame["override"]}, TestID -> "explicit send options override connection defaults"],
    VerificationTest[Module[{h = echoHandler[]}, h["MessageHandler"] = <|"echo" -> (Function[True] -> Function[{client, message}, message])|>;
        h[packet[masked["route"]]]], WebSocketFrame["route"], TestID -> "conditional callback routing"],
    VerificationTest[WebSocketPacketQ[packet[request, "new"]], True, TestID -> "recognize upgrade"],
    VerificationTest[WebSocketPacketQ[<||>], False, TestID -> "reject invalid packet"],
    VerificationTest[WebSocketPacketLength[packet[Join[request, masked["x"]]]], Length[request], TestID -> "handshake excludes following frame"],
    VerificationTest[WebSocketPacketLength[packet[ByteArray[{129}]]], 2, TestID -> "partial base header"],
    VerificationTest[WebSocketPacketLength[packet[ByteArray[{129, 126, 0}]]], 4, TestID -> "partial extended header"],
    VerificationTest[And @@ Flatten[Table[WebSocketPacketLength[packet[WebSocketFrame[ByteArray[ConstantArray[0, n]], "Masking" -> mask]]] === n +
        If[n < 126, 2, If[n < 65536, 4, 10]] + If[mask, 4, 0], {n, {0, 125, 126, 65535, 65536}}, {mask, {False, True}}]], True, TestID -> "length boundaries masked and unmasked"],
    VerificationTest[Module[{h = echoHandler[], input = ByteArray[ConstantArray[255, 65536]]}, h[packet[masked[input]]]],
        WebSocketFrame[ByteArray[ConstantArray[255, 65536]]], TestID -> "64bit length binary roundtrip"]
};


TestReport[tests]

