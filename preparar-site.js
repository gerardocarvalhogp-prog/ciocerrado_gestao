#!/usr/bin/env node
// =====================================================================
// Monta a pasta _site que vai para o Netlify.
//
// POR QUE ISSO EXISTE
//
// O deploy antigo publicava a raiz inteira. Com isso foram para o ar,
// em URL publica, o schema.sql, as migrations, o CLAUDE.md e o
// integracao.py — conferido em 24/08/2026:
//
//   https://ciocerrado.netlify.app/schema.sql          200
//   https://ciocerrado.netlify.app/gestao/CLAUDE.md    200
//
// Nao vazou dado pessoal (participantes_rows.csv e as planilhas estao
// no .gitignore e o CLI pulou), mas o mapa completo do banco ficou
// publico — e a chave anon tambem e publica, por design. Nao ha motivo
// para entregar as duas coisas juntas.
//
// A REGRA
//
// So vai para o ar o arquivo que atende as DUAS condicoes:
//
//   1. esta versionado no git  (`git ls-files`)
//   2. tem extensao de web     (lista abaixo)
//
// A primeira condicao e a que protege dado pessoal: os .csv e as
// planilhas de participante estao no .gitignore justamente por isso, e
// arquivo ignorado nunca aparece no `git ls-files`. A segunda tira
// .sql, .py, .md, .toml e .ts.
//
// COMO USAR
//
//   node preparar-site.js
//   netlify deploy --dir=_site            (preview, URL temporaria)
//   netlify deploy --dir=_site --prod     (producao)
// =====================================================================

const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const RAIZ = __dirname;
const DESTINO = path.join(RAIZ, "_site");

const EXTENSOES_WEB = new Set([
  ".html", ".css", ".js", ".mjs", ".map",
  ".png", ".jpg", ".jpeg", ".webp", ".svg", ".gif", ".ico",
  ".woff", ".woff2", ".ttf",
  ".pdf", ".xlsx", ".txt", ".json", ".xml",
]);

// `-z` porque os nomes tem espaco e acento ("Programaçao massagens...")
const versionados = execFileSync("git", ["ls-files", "-z"], {
  cwd: RAIZ,
  maxBuffer: 32 * 1024 * 1024,
})
  .toString("utf8")
  .split("\0")
  .filter(Boolean);

const publicaveis = versionados.filter((rel) =>
  EXTENSOES_WEB.has(path.extname(rel).toLowerCase())
);

// Recomeca do zero: arquivo removido do repositorio tem que sumir do
// _site tambem, senao continua no ar depois do proximo deploy.
fs.rmSync(DESTINO, { recursive: true, force: true });

for (const rel of publicaveis) {
  const destino = path.join(DESTINO, rel);
  fs.mkdirSync(path.dirname(destino), { recursive: true });
  fs.copyFileSync(path.join(RAIZ, rel), destino);
}

const descartados = versionados.length - publicaveis.length;
console.log(`_site pronto: ${publicaveis.length} arquivo(s).`);
console.log(`${descartados} arquivo(s) versionado(s) ficaram de fora por nao serem web.`);
console.log("");
for (const rel of publicaveis) console.log("  " + rel.replace(/\//g, path.sep));
