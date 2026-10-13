// Block skeleton of each document per markdown-it (CommonMark 0.31 + GFM tables/strikethrough), the reference.
// usage: node reference.js <folder with node_modules/markdown-it> <corpus.json> <out.json>
const [, , pkg, corpusPath, outPath] = process.argv;
const MarkdownIt = require(require('path').join(pkg, 'node_modules', 'markdown-it'));
const md = new MarkdownIt('commonmark').enable(['table', 'strikethrough']);
const fs = require('fs');
const docs = JSON.parse(fs.readFileSync(corpusPath, 'utf8'));
function skeleton(src) {
  const toks = md.parse(src, {});
  const out = [];
  let i = 0;
  while (i < toks.length) {
    const t = toks[i];
    if (t.level !== 0) { i++; continue; }
    switch (t.type) {
      case 'heading_open': out.push('h' + t.tag.slice(1)); break;
      case 'paragraph_open': out.push('p'); break;
      case 'fence': case 'code_block': out.push('code'); break;
      case 'hr': out.push('hr'); break;
      case 'html_block': out.push('html'); break;
      case 'blockquote_open': {
        out.push('quote');
        let depth = 0;
        for (; i < toks.length; i++) {
          if (toks[i].type === 'blockquote_open') depth++;
          if (toks[i].type === 'blockquote_close') { depth--; if (depth === 0) break; }
        }
        break;
      }
      case 'table_open': {
        let rows = 0, cols = 0, firstRow = true;
        for (; i < toks.length && toks[i].type !== 'table_close'; i++) {
          if (toks[i].type === 'tr_open') rows++;
          if (toks[i].type === 'tr_close') firstRow = false;
          if (firstRow && toks[i].type === 'th_open') cols++;
        }
        out.push(`table${rows}x${cols}`);
        break;
      }
      case 'bullet_list_open': case 'ordered_list_open': {
        const items = [];
        const stack = [];
        for (; i < toks.length; i++) {
          const k = toks[i];
          if (k.type === 'bullet_list_open' || k.type === 'ordered_list_open') stack.push(k.type[0] === 'b' ? 'u' : 'o');
          if (k.type === 'bullet_list_close' || k.type === 'ordered_list_close') { stack.pop(); if (stack.length === 0) break; }
          if (k.type === 'list_item_open') items.push(stack[stack.length - 1] + (stack.length - 1));
        }
        out.push('list(' + items.join(',') + ')');
        break;
      }
    }
    i++;
  }
  // Lists of one kind split only by blank lines read as one list.
  const merged = [];
  for (const b of out) {
    const prev = merged[merged.length - 1];
    if (prev && prev.startsWith('list(') && b.startsWith('list(') && prev[5] === b[5]) merged[merged.length - 1] = prev.slice(0, -1) + ',' + b.slice(5);
    else merged.push(b);
  }
  return merged;
}
fs.writeFileSync(outPath, JSON.stringify(docs.map(skeleton)));
console.log('reference skeletons:', docs.length);
