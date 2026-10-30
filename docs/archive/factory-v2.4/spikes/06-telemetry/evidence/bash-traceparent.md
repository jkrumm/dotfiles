|run|worker|root span (warden)|span id Bash saw|that span is|same trace as warden root|
|-|-|-|-|-|-|
|A|headless -p|c3b7f88d|c3b7f88d|the warden root span itself (inherited, not injected)|True|
|B|headless -p|bee74ec4|a400a3be|claude_code.tool.execution|True|
|S|headless -p|54a08d3a|db8a4c92|claude_code.tool.execution|True|
|I|interactive|74e13b3b|33a86a7b|claude_code.tool.execution|False|
