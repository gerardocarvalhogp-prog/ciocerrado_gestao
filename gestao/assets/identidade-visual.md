# Identidade visual — tokens de marca

Extraído de `ciocerrado.com.br` (home institucional, marca-mãe — não confundido
com sub-eventos como CIO Experience, IA Experience, Public Connection) em
28/08/2026. Fonte de cada valor documentada abaixo para poder reconferir depois.

## Cores

| Token | Valor | Onde apareceu no site | Uso recomendado |
|---|---|---|---|
| Verde da marca | `#387828` | Contorno/"folha" do símbolo oficial (`site-patrocinador.png`) | símbolo, acentos de marca |
| Laranja/dourado do símbolo | `#E8A800` | Fundo do símbolo oficial (mesmo arquivo) | cor mais autoritativa de "laranja da marca" — é o próprio logo, não uma escolha de conteúdo |
| Laranja de CTA/destaque | `#FFA217` | `color:#ffa217` inline, repetido 9× em textos de call-to-action na home | usado pelo site em texto de link/destaque — mais vívido que o do símbolo, provavelmente escolhido à mão por quem editou a página, não formalmente do kit de marca |
| Fundo predominante | `#FFFFFF` | `body{background-color:#fff}` no CSS global do tema | o site NÃO é dark-theme — o visual escuro do topo da home é foto de herói com overlay, não uma cor sólida da marca |
| Texto do corpo | `#333333` | `body{color:#333}` | — |
| Roxo/índigo secundário | `#251B58` | Fundo de UMA seção decorativa (com textura gráfica) | uso pontual, não é cor recorrente — não tratar como primária |

**Não confiar nas variáveis `--e-global-color-*` do Elementor** (`#6EC1E4`,
`#54595F`, `#7A7A7A`, `#61CE70`) — são a paleta padrão de fábrica do Elementor,
nunca customizada pelo cliente. Ignoradas nesta extração.

## Tipografia

- **Título/destaque**: Montserrat, peso 600 (confirmado via estilo computado do
  `<h1>` da home). Carregada via Google Fonts em pesos 100–900.
- **Kit Elementor declara** `primary`/`text` = Roboto, `secondary` = Roboto Slab
  — mas o `body{}` do tema usa pilha de fontes do sistema operacional
  (`-apple-system, Segoe UI, Roboto, ...`), com Roboto só como 3º fallback. Ou
  seja: o corpo de texto do site **não tem uma fonte de marca deliberada**, é
  reset de sistema. Não há uma "fonte de corpo oficial" clara para herdar daí.

## Logo

- **Wordmark completo** (ícone + "CIO Cerrado"): `assets/logo-oficial-wordmark.png`
  — extraído de `https://ciocerrado.com.br/wp-content/uploads/2023/12/Sem-Titulo-1-1.png`
  (1080×419, linkado a partir da home). **É branco sobre fundo transparente** —
  só funciona sobre fundo escuro ou colorido, fica invisível em fundo claro.
- **Símbolo isolado** (a árvore + folha, sem o texto): `assets/icons/simbolo-oficial-master.png`
  — derivado de `https://ciocerrado.com.br/wp-content/uploads/2023/12/site-patrocinador.png`
  (a fonte usada pelo próprio favicon do site institucional, 251×200 original).
  Corrigido aqui: a "árvore branca" no arquivo original na verdade é um recorte
  **transparente**, não branco opaco — funciona por acidente sobre fundo branco e
  desapareceria sobre fundo escuro. Achatei o recorte interno para branco opaco
  de verdade (mantendo transparente só a área externa ao emblema), pra ficar
  confiável em qualquer fundo. Ver `favicon.ico`/PNGs gerados a partir deste master.
- **Achado colateral**: o favicon do PRÓPRIO site institucional
  (`cropped-site-patrocinador-*.png`) tem o mesmo problema que este sistema
  tinha — nome de arquivo literalmente "recorte de [imagem de] patrocinador".
  Não dá pra copiar o favicon deles como referência de "como deveria ser feito";
  o símbolo em si é bom, o recorte/processo é que era descuidado — dos dois lados.

## Comparação com os tokens já usados neste sistema

O `assets/design-system.css` deste projeto já usava, antes desta extração:
`--verde:#14312B` e `--ouro:#A8842C`. Comparado à marca real:

- **Direção certa, saturação errada**: os dois já eram "verde escuro + dourado",
  a mesma família de cor do símbolo oficial — não é uma paleta inventada do zero.
- **Mas bem mais escuros/dessaturados** que a marca: o verde do símbolo
  (`#387828`) é bem mais claro e saturado que o `#14312B` do sistema; o
  laranja/dourado do símbolo (`#E8A800`) é mais vívido e mais alaranjado que o
  `#A8842C` do sistema, que puxa mais para um marrom-dourado apagado.

Fica a critério do Gerardo se isso é intencional (dessaturado de propósito para
uso prolongado em tela, prática comum em ferramentas internas) ou se deveria ser
corrigido para casar mais de perto com a marca real — é uma mudança grande,
visível em toda tela, e não foi aplicada nesta rodada sem confirmação.
