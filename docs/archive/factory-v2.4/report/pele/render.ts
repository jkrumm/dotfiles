// Mermaid source on stdin → SVG on stdout, rendered by pele (Mermaid 12 syntax, own layout,
// themed through --pele-* CSS variables). Called by build.py for every ```mermaid fence.
import { render } from "pele";

const source = await Bun.stdin.text();
const { svg } = render(source);
process.stdout.write(svg);
