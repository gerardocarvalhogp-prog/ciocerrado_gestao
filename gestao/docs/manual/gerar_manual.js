// Gera o Manual do Sistema de Gestao (CIO Cerrado) em .docx
// Conteudo derivado da documentacao funcional conferida em docs/ (2026-09-01)

const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType,
  Table, TableRow, TableCell, WidthType, ShadingType, BorderStyle,
  LevelFormat, PageBreak, TableOfContents, ExternalHyperlink,
} = require("docx");
const fs = require("fs");

// ---------------------------------------------------------------------
// PALETA E ESTILO
// ---------------------------------------------------------------------
const VERDE = "1F5C3F";      // verde CIO Cerrado, mais escuro para texto
const VERDE_CLARO = "E4F0EA";
const DOURADO = "9C6B1E";
const CINZA_TEXTO = "2B2B2B";
const CINZA_SUAVE = "6B6B6B";
const LINHA = "D9D2C4";

const FONTE_CORPO = "Calibri";
const FONTE_TITULO = "Calibri";

// ---------------------------------------------------------------------
// HELPERS
// ---------------------------------------------------------------------
function h1(texto) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_1,
    spacing: { before: 480, after: 240 },
    children: [new TextRun({ text: texto, bold: true, color: VERDE, size: 32, font: FONTE_TITULO })],
  });
}
function h2(texto) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_2,
    spacing: { before: 360, after: 160 },
    children: [new TextRun({ text: texto, bold: true, color: VERDE, size: 26, font: FONTE_TITULO })],
  });
}
function h3(texto) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_3,
    spacing: { before: 260, after: 120 },
    children: [new TextRun({ text: texto, bold: true, color: DOURADO, size: 22, font: FONTE_TITULO })],
  });
}
function p(texto, opts = {}) {
  return new Paragraph({
    spacing: { after: 180, line: 300 },
    children: [new TextRun({ text: texto, size: 22, color: CINZA_TEXTO, font: FONTE_CORPO, ...opts })],
  });
}
function pRich(runs, opts = {}) {
  return new Paragraph({
    spacing: { after: 180, line: 300 },
    children: runs,
    ...opts,
  });
}
function bold(texto) { return new TextRun({ text: texto, bold: true, size: 22, color: CINZA_TEXTO, font: FONTE_CORPO }); }
function reg(texto) { return new TextRun({ text: texto, size: 22, color: CINZA_TEXTO, font: FONTE_CORPO }); }
function ital(texto) { return new TextRun({ text: texto, italics: true, size: 22, color: CINZA_SUAVE, font: FONTE_CORPO }); }

function bullet(texto, nivel = 0) {
  return new Paragraph({
    numbering: { reference: "lista-padrao", level: nivel },
    spacing: { after: 100, line: 290 },
    children: [new TextRun({ text: texto, size: 22, color: CINZA_TEXTO, font: FONTE_CORPO })],
  });
}
function bulletRich(runs, nivel = 0) {
  return new Paragraph({
    numbering: { reference: "lista-padrao", level: nivel },
    spacing: { after: 100, line: 290 },
    children: runs,
  });
}

// caixa de destaque ("regra importante" / "atencao")
function callout(titulo, texto, cor = VERDE, corFundo = VERDE_CLARO) {
  return new Table({
    width: { size: 9350, type: WidthType.DXA },
    columnWidths: [9350],
    borders: {
      top: { style: BorderStyle.SINGLE, size: 4, color: cor },
      bottom: { style: BorderStyle.SINGLE, size: 4, color: cor },
      left: { style: BorderStyle.SINGLE, size: 24, color: cor },
      right: { style: BorderStyle.SINGLE, size: 4, color: cor },
      insideHorizontal: { style: BorderStyle.NONE, size: 0, color: "FFFFFF" },
      insideVertical: { style: BorderStyle.NONE, size: 0, color: "FFFFFF" },
    },
    rows: [
      new TableRow({
        children: [
          new TableCell({
            width: { size: 9350, type: WidthType.DXA },
            shading: { type: ShadingType.CLEAR, fill: corFundo },
            margins: { top: 160, bottom: 160, left: 220, right: 220 },
            children: [
              new Paragraph({
                spacing: { after: 60 },
                children: [new TextRun({ text: titulo, bold: true, size: 21, color: cor, font: FONTE_CORPO })],
              }),
              new Paragraph({
                spacing: { after: 0, line: 280 },
                children: [new TextRun({ text: texto, size: 21, color: CINZA_TEXTO, font: FONTE_CORPO })],
              }),
            ],
          }),
        ],
      }),
    ],
  });
}

function espaco(altura = 120) {
  return new Paragraph({ spacing: { after: altura }, children: [] });
}

function quebraDePagina() {
  return new Paragraph({ children: [new PageBreak()] });
}

// tabela simples de 2 colunas (rotulo / descricao)
function tabelaDuasColunas(linhas, largCol1 = 2600, largCol2 = 6750) {
  const linhaCabecalho = new TableRow({
    tableHeader: true,
    children: [
      new TableCell({
        width: { size: largCol1, type: WidthType.DXA },
        shading: { type: ShadingType.CLEAR, fill: VERDE },
        margins: { top: 100, bottom: 100, left: 150, right: 150 },
        children: [new Paragraph({ children: [new TextRun({ text: linhas.cab1, bold: true, color: "FFFFFF", size: 20, font: FONTE_CORPO })] })],
      }),
      new TableCell({
        width: { size: largCol2, type: WidthType.DXA },
        shading: { type: ShadingType.CLEAR, fill: VERDE },
        margins: { top: 100, bottom: 100, left: 150, right: 150 },
        children: [new Paragraph({ children: [new TextRun({ text: linhas.cab2, bold: true, color: "FFFFFF", size: 20, font: FONTE_CORPO })] })],
      }),
    ],
  });
  const corpo = linhas.itens.map((it, i) => new TableRow({
    children: [
      new TableCell({
        width: { size: largCol1, type: WidthType.DXA },
        shading: { type: ShadingType.CLEAR, fill: i % 2 === 0 ? "F7F5EF" : "FFFFFF" },
        margins: { top: 100, bottom: 100, left: 150, right: 150 },
        children: [new Paragraph({ children: [new TextRun({ text: it[0], bold: true, size: 20, color: CINZA_TEXTO, font: FONTE_CORPO })] })],
      }),
      new TableCell({
        width: { size: largCol2, type: WidthType.DXA },
        shading: { type: ShadingType.CLEAR, fill: i % 2 === 0 ? "F7F5EF" : "FFFFFF" },
        margins: { top: 100, bottom: 100, left: 150, right: 150 },
        children: [new Paragraph({ children: [new TextRun({ text: it[1], size: 20, color: CINZA_TEXTO, font: FONTE_CORPO })] })],
      }),
    ],
  }));
  return new Table({
    width: { size: largCol1 + largCol2, type: WidthType.DXA },
    columnWidths: [largCol1, largCol2],
    borders: {
      top: { style: BorderStyle.SINGLE, size: 2, color: LINHA },
      bottom: { style: BorderStyle.SINGLE, size: 2, color: LINHA },
      left: { style: BorderStyle.SINGLE, size: 2, color: LINHA },
      right: { style: BorderStyle.SINGLE, size: 2, color: LINHA },
      insideHorizontal: { style: BorderStyle.SINGLE, size: 2, color: LINHA },
      insideVertical: { style: BorderStyle.SINGLE, size: 2, color: LINHA },
    },
    rows: [linhaCabecalho, ...corpo],
  });
}

module.exports = {
  h1, h2, h3, p, pRich, bold, reg, ital, bullet, bulletRich, callout, espaco,
  quebraDePagina, tabelaDuasColunas, VERDE, VERDE_CLARO, DOURADO, CINZA_TEXTO,
  CINZA_SUAVE, LINHA, FONTE_CORPO, FONTE_TITULO,
  Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType,
  Table, TableRow, TableCell, WidthType, ShadingType, BorderStyle,
  LevelFormat, PageBreak, TableOfContents, ExternalHyperlink, fs,
};
