// writes ../src/Assets.eco from dist/: one std::embed::bytes per file, a gzipped copy beside each
// file that shrinks, and an entity tag from its content. Run by `npm run build`; commit dist/ and
// the table, since an app that depends on nexus-debug runs no hooks of its.

import { createHash } from 'node:crypto'
import { readdirSync, readFileSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { join, relative, extname } from 'node:path'
import { gzipSync } from 'node:zlib'
import { fileURLToPath } from 'node:url'

const ui = fileURLToPath(new URL('..', import.meta.url))
const dist = join(ui, 'dist')
const out = join(ui, '..', 'src', 'Assets.eco')

const types = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.woff': 'font/woff',
  '.txt': 'text/plain; charset=utf-8',
}
const squeezable = new Set(['.html', '.js', '.mjs', '.css', '.json', '.svg', '.txt'])

function walk(dir) {
  return readdirSync(dir).flatMap((name) => {
    const at = join(dir, name)
    return statSync(at).isDirectory() ? walk(at) : [at]
  })
}

// gzipped copies from an earlier build go first
for (const f of walk(dist)) if (f.endsWith('.gz')) unlinkSync(f)

const entries = []
for (const file of walk(dist).sort()) {
  const path = relative(dist, file).split('\\').join('/')
  const ext = extname(file)
  const type = types[ext]
  if (!type) throw new Error(`no content type for ${path}; add one to scripts/embed.mjs`)
  const bytes = readFileSync(file)
  let gz = ''
  if (squeezable.has(ext) && path !== 'index.html') {
    const packed = gzipSync(bytes, { level: 9 })
    if (packed.length < bytes.length * 0.9) {
      writeFileSync(`${file}.gz`, packed)
      gz = `${path}.gz`
    }
  }
  const etag = `"${createHash('sha256').update(bytes).digest('hex').slice(0, 16)}"`
  entries.push({ path, type, gz, etag })
}

const lines = entries.map((e) => {
  const body = `std::embed::bytes('../ui/dist/${e.path}')`
  const gzip = e.gz ? `std::embed::bytes('../ui/dist/${e.gz}')` : "''"
  return `        if ($path == '${e.path}') {
            return Asset('${e.path}', '${e.type}', ${body}, ${gzip}, '${e.etag.replaceAll("'", "\\'")}');
        }`
})

writeFileSync(
  out,
  `namespace nexus::debug;

// written by ui/scripts/embed.mjs from ui/dist; do not edit

/**
 * The files of the embedded web app.
 */
public struct Assets
{
    /**
     * The file at \`$path\` (\`index.html\`, \`assets/index-abc.js\`), or null.
     */
    public static function find(const string& $path) : Asset?
    {
${lines.join('\n')}
        return null;
    }
}
`,
)
console.log(`embed     ${entries.length} files, ${entries.filter((e) => e.gz).length} gzipped -> ${relative(join(ui, '..'), out)}`)
