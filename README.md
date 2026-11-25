# WebSocket

An independent WebSocket protocol handler for Wolfram Language. The core uses
`WLJS/Objects`. The optional server and client adapters use `WLJS/CSockets`
(1.0.26 or newer). Loading the package neither opens sockets nor installs paclets.
The package context remains ``KirillBelov`WebSocket` ``.

```wl
Needs["KirillBelov`WebSocket`"];
handler = WebSocketHandler[
    "Handshake" -> False,
    "DefaultMessageHandler" -> Function[{client, message}, message]
];
response = handler[<|
    "SourceSocket" -> "synthetic-client",
    "DataByteArray" -> WebSocketFrame["hello", "Masking" -> True]
|>];
response === WebSocketFrame["hello"]
```

`SourceSocket` is an arbitrary connection identifier, including a string or an
integer. `DataByteArray` contains any chunk of the input stream, including partial
headers and multiple frames. The handler buffers bytes and message fragments per
connection. By default it first expects an HTTP upgrade request; `"Handshake" ->
False` starts directly with frames. Server mode requires masked incoming frames;
`"Role" -> "Client"` requires unmasked frames and masks outgoing frames.

The return value is `Null` when no response is needed, or a `ByteArray` containing
one or more complete wire responses. A successful handshake returns HTTP response
bytes. A close or protocol error returns a close frame and removes connection
state; the transport should write the response before closing the connection.
Malformed handshakes and invalid packet associations return `$Failed`.

Callbacks receive `(client, message)`. Text messages arrive as UTF-8 strings,
binary messages as `ByteArray`; `"Deserializer"` (default `Identity`) is applied
after decoding and reassembling the message. A callback's string result produces
a text frame, a `ByteArray` result produces a binary frame, and `Null` sends
nothing. Other results pass through `"Serializer"` (default `ToString`).
`"MessageHandler"` accepts either a function or named conditional rules:

```wl
handler["MessageHandler"] = <|
    "Echo" -> (Function[True] -> Function[{client, message}, message])
|>;
```

The first matching rule wins; otherwise `"DefaultMessageHandler"` is called
(default: return `Null`). Ping replies contain the original payload, pong frames
do not reach message callbacks, and control frames can occur between fragments.
Invalid framing closes with 1002; invalid UTF-8 closes with 1007.

To send independently of an incoming packet, pass the encoding and transport
options directly to `WebSocketSend`:

```wl
WebSocketSend["synthetic-client", {0, 255},
    "Serializer" -> ByteArray,
    "Masking" -> False,
    "SendFunction" -> Function[{client, bytes}, Print[{client, bytes}]]
];
```

`WebSocketSend` defaults to `"Serializer" -> ToString`, `"Masking" -> False`
(server output), and `"SendFunction" -> BinaryWrite`. Use `"Masking" -> True`
for client output. Strings and byte arrays are already serialized; other values
pass through the serializer. The serialized type selects text or binary framing;
`Null` suppresses sending. Sending does not look up a handler or connection state.

`WebSocketSend[connection, expression, opts]` uses the client connection's
serializer, client masking and transport function as defaults. Explicit options
override those defaults for that send.

The handler's `"SendFunction"` and `"CloseFunction"` configure its transport
adapter. `Close[handler]` clears buffered state and closes its connections.
All connection, handshake, input-buffer and message-fragment state belongs to
the handler object. Independent handlers can use the same connection identifier.

`WebSocketPacketQ[packet]` recognizes an HTTP GET prefix. It needs the first four
HTTP bytes to recognize a new connection. `WebSocketPacketQ[handler, packet]`
also recognizes established connections and pending input in that handler's
`"Connections"` and `"Buffer"` fields. For example, a conditional transport
callback can use `Function[WebSocketPacketQ[handler, #]]` as its predicate.
`WebSocketPacketLength[packet]` returns the first HTTP header/frame length. With
an incomplete frame header it returns the next required header size. It accounts
for the mask bit and all three payload-length encodings.

## CSockets

```wl
server = WebSocketServerCreate[8080, <|
    "Echo" -> (Function[True] -> Function[{client, message}, message])
|>];
client = WebSocketConnect["ws://localhost:8080/chat"];
WebSocketSend[client, "hello"];
SocketReadyQ[client, 1];
SocketReadMessage[client]
Close[client];
Close[server];
```

The server exposes `"Socket"`, `"Listener"` and `"TransportHandler"`. The adapter
uses CSockets' `"Received"`, `"Closed"` and `"Error"` events. Leave its accumulator
at the default chunk length: WebSocketHandler assembles the stream itself.
CSockets stores its accumulator's expected length after the first chunk, so a
progressively parsed WebSocket header cannot be used directly as that accumulator
when the first chunk contains only part of the header. Do not install the old
`"Handler"` event mapping.

The client validates the server's upgrade response, buffers partial and coalesced
frames, handles control frames and queues complete messages. `SocketReadMessage`
returns the next complete message or `$Failed` if none is available yet. `ws://`
is supported; TLS (`wss://`), extensions and subprotocol negotiation are not
implemented.

## Tests

Run `wolframscript -f Tests/RunTests.wls` from this directory. The suite covers
synthetic streams, frame lengths, UTF-8, fragmentation and control frames, then
checks the current CSockets event adapter and real loopback text/binary traffic.
Run Wolfram kernels sequentially because of the free engine license limit.
Protocol reference: [RFC 6455](https://www.rfc-editor.org/rfc/rfc6455.html).
