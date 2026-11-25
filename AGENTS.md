## Wolfram Language Code Style Guide

- Use two blank lines between blocks in a .wl file.
- Use only one blank line after (* :Package: *) because it affects formatting and display in Mathematica.
- In a multiline Begin or BeginPackage expression, keep the first argument (the package name) on the first line. 
- Use 4 spaces for indentation.
- Do not use tabs.
- Place the left-hand side of a function definition (before :=) on the first line.
- Place the right-hand side of a function definition on the next line. 
- Example:

```wl
funcName[x_, y_] :=
x + y;
```

- Separate symbols, operators, and words with spaces, except at the end of a line and as specified by the exceptions below.
- End every definition with a semicolon.
- Do not put a space before a comma; put a space after it. Example: `{1, 2, 3, 4}`.
- Do not put a space after `!` (the `Not` operator).
- Do not put a space before `:` (the `Pattern` function).
- Do not put a space before `&` (the function terminator in `(# + 1)&`).
- Treat /@, /:, /;, /@@, @*, and other operator shorthands as single operators. Do not insert spaces inside them.
- Do not put a space before a semicolon; put a space after it unless it ends the line. Example: `x = 1;`.
- Write all usage declarations on two or more lines, like function definitions. Example:

```wl
funcName::usage = 
"funcName[x, y] - returns x + y.";
```

- Long signatures on the left-hand side of definitions may span multiple lines.

```wl
func[
    x, y, z,
    z, b, c
] := 
Total[{x, y, z, a, b, c}];
```

- Use the most precise argument types possible: `f[x_]` is discouraged; `createAddressStorage[host_String, port_Integer]` is preferred.
- Definitions of nonlocal internal package variables and constants should also span two or more lines when the right-hand side is long: put the left-hand side and equals sign on the first line, and the right-hand side on the next. Keep short definitions such as `$const = 1.0` on one line when the right-hand side is not a complex code block.

```wl
$directory = 
DirectoryName[..];
```

- For memoized constants and global variables, keep the left-hand side on one line.

```wl
$icon := $icon =
Import["icon.png"];
```

- Format multiline expressions, lists, and associations in C# block style. Examples:

```wl
(*standalone multiline list*)
{
    1, 
    2, 
    3
}


(*standalone multiline association*)
<|
    1 -> 2, 
    2 -> 3, 
    3 -> 1
|>


(*standalone multiline expression*)
expr[
    1, 
    2 -> 3, 
    f[x]
]
```

- When assigning a multiline list, expression, or association, place its opening on the same line as the assignment.

```wl
(*multiline list assignment*)
l = {
    1, 
    2, 
    3
};


(*multiline association assignment*)
a = <|
    1 -> 2, 
    2 -> 3, 
    3 -> 1
|>;


(*multiline expression assignment*)
e = expr[
    1, 
    2 -> 3, 
    f[x]
];
```

- For scoping constructs, keep a short first argument on the first line. If it is long, keep the opening of its list on the first line.

```wl
With[{x = 1}, 
    x + 1
];


Module[{
    x = 1, 
    y = 2
}, 
    x + y
];
```

- In a multiline If or Switch expression, keep the condition or selector on the first line.

```wl
If[x != y, 
    x, 
    y
];


Swicth[x, 
    1, 2, 
    2, 3
];
```

## Architecture

- Preserve WebSocketPacketQ, WebSocketPacketLength and WebSocketHandler as the protocol core.
- Preserve the ASCII flow diagram at the beginning of Kernel/WebSocket.wl and update it when protocol flow changes; it is part of the architecture documentation.
- The core depends on WLJS`Objects`, but must load and operate without CSockets or network access. Never install dependencies during package loading.
- Accept synthetic packet associations with SourceSocket (any connection identifier) and DataByteArray. Keep transport and message-fragment buffers per handler and per connection.
- Keep all mutable connection and handshake state inside WebSocketHandler. Do not introduce a package-global client-to-handler registry. Stateful packet recognition takes the handler explicitly.
- WebSocketSend[client, expression, opts] receives Serializer, Masking and SendFunction explicitly as options; it must not discover a handler from a client identifier.
- Return encoded responses from incoming packet handling. Use the configurable SendFunction and CloseFunction for explicitly initiated transport operations.
- String results use text frames; ByteArray results use binary frames. Null produces no response.
- CSockets integration uses WLJS`CSockets` and its Received/Closed/Error events. Do not use the obsolete Handler event.

## Tests

- Run from the repository root with `wolframscript -f Tests/RunTests.wls`.
- Run Wolfram commands sequentially because the free engine license limits concurrent kernels.
- If a kernel process crashes, retry once after it exits. Report persistent process crashes separately from assertion failures.
- Cover synthetic packets as well as the CSockets adapter. Test partial headers, coalesced frames, fragmentation, text/binary results and control frames.
