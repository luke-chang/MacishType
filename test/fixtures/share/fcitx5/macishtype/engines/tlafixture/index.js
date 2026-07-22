// Sequential, dependent top-level awaits on fetch: the second path is only
// known after the first resolves, so the host's synchronous fallback must
// loop — each settled generation resumes the module far enough to queue the
// next fetch. A single-pass flush loads only single-await modules.
const index = await fetch("./index.json").then((response) => response.json());
const table = await fetch(index.next).then((response) => response.json());
console.log(`tla loaded entries=${Object.keys(table).length}`);

export default class {}
