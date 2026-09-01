const M = require("./gerar_manual.js");
const conteudo = require("./conteudo.js");
const { Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType,
  LevelFormat, fs } = M;
const { Header, Footer, PageNumber } = require("docx");

const doc = new Document({
  creator: "CIO Cerrado",
  title: "Manual do Sistema de Gestão — CIO Cerrado",
  description: "Guia didático do sistema de gestão de eventos para sócios e equipe de apoio.",
  numbering: {
    config: [
      {
        reference: "lista-padrao",
        levels: [
          { level: 0, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT,
            style: { paragraph: { indent: { left: 420, hanging: 260 } } } },
          { level: 1, format: LevelFormat.BULLET, text: "◦", alignment: AlignmentType.LEFT,
            style: { paragraph: { indent: { left: 840, hanging: 260 } } } },
        ],
      },
    ],
  },
  styles: {
    default: {
      document: { run: { font: M.FONTE_CORPO, size: 22, color: M.CINZA_TEXTO } },
    },
  },
  sections: [
    {
      properties: {
        page: {
          size: { width: 12240, height: 15840 }, // US Letter, DXA
          margin: { top: 1300, bottom: 1300, left: 1300, right: 1300 },
        },
      },
      headers: {
        default: new Header({
          children: [new Paragraph({
            alignment: AlignmentType.RIGHT,
            children: [new TextRun({ text: "CIO Cerrado — Manual do Sistema de Gestão", size: 16, color: M.CINZA_SUAVE, font: M.FONTE_CORPO })],
          })],
        }),
      },
      footers: {
        default: new Footer({
          children: [new Paragraph({
            alignment: AlignmentType.CENTER,
            children: [
              new TextRun({ text: "Página ", size: 16, color: M.CINZA_SUAVE, font: M.FONTE_CORPO }),
              new TextRun({ children: [PageNumber.CURRENT], size: 16, color: M.CINZA_SUAVE, font: M.FONTE_CORPO }),
            ],
          })],
        }),
      },
      children: conteudo,
    },
  ],
});

Packer.toBuffer(doc).then(buf => {
  fs.writeFileSync(__dirname + "/Manual_Sistema_Gestao_CIO_Cerrado.docx", buf);
  console.log("gerado:", __dirname + "/Manual_Sistema_Gestao_CIO_Cerrado.docx");
});
