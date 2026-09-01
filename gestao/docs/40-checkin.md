# Check-in — `checkin.html`

Tela operada no dia do evento.

**Correção ao rascunho:** a tela **lê, sim, `?evento=`** — só que com
`cerrado2027` como padrão se o parâmetro faltar, então na prática costuma
rodar sem precisar passar nada. Também lê `?jantar=<uuid>`, que troca o
escopo inteiro para um jantar avulso específico (jantar não tem `evento_id` —
design deliberado, ver `50-jantares.md` — por isso não reaproveita
`checkin_*`/`v_esperados`, usa `jantar_checkin_*` à parte), e `?local=`, usado
para registrar onde o check-in aconteceu.

---

## Contexto de uso, que define os requisitos

Quem opera esta tela é staff contratado para o dia: tipicamente uma estudante de
16 anos de Alexânia, que usa bem o celular para redes sociais mas nunca operou
sistema de gestão. Ela não sabe o que é filtro, exportar ou registro, e tem medo
de clicar e estragar. Trabalha **em pé, com fila na frente, sem ninguém para
perguntar.**

Isso não é detalhe de contexto: é a especificação. Toda decisão de design desta
tela responde a uma pergunta só — *ela consegue sozinha, na primeira vez, com
pressa?*

Consequências:

- Busca por nome que funcione com nome parcial e sem acento.
- Ação principal única e óbvia por pessoa encontrada.
- Confirmação visual inequívoca de que o check-in foi registrado.
- Nada destrutivo a um clique de distância.
- Funcionamento pleno no celular, em pé, com uma mão.
- Linguagem sem jargão de sistema.

---

## O que a tela faz

- Localizar a pessoa por busca de nome, **ou por leitura de QR** (ver seção
  própria abaixo — ao contrário do que o rascunho registrava, isto já existe).
- Registrar a chegada (`checkin_registrar`, ou `jantar_checkin_registrar` no
  modo jantar).
- Listar quem já chegou e resumo por empresa (`checkin_listar`,
  `checkin_resumo`).
- Cadastrar alguém na hora que não está na base (`checkin_cadastrar`) — para
  quem chega sem estar em `v_esperados`.

*A confirmar: a tela mostra pendência financeira ou de contrato no momento do
check-in? Não encontrei esse cruzamento nas funções lidas — parece mostrar só
identificação e categoria de crachá, sem bloqueio por pendência, mas não
confirmei linha a linha.*

---

## Regras

- Check-in duplicado não gera registro duplicado — `checkin_registrar` consulta
  antes de inserir e devolve `ja_estava: true` em vez de duplicar (é validação
  de função, não `UNIQUE` de banco — ver `70-modelo-de-dados.md`).
- **Desfazer existe** — botão "Desfazer" em cada linha de quem já entrou, que
  chama `checkin_desfazer` (ou `jantar_checkin_desfazer` no modo jantar). Não
  apaga a linha: marca `checkins.desfeito_em`, preservando o registro.
- `checkins.registrado_por` grava o e-mail de quem operou o check-in — **a
  tela registra, sim, quem fez cada check-in.**
- O staff não altera cadastro pela tela de check-in — confirmado: nenhuma
  função de check-in escreve em `gestores`, só em `checkins`.

*A confirmar: existe modo offline ou tolerância a queda de rede? Não
encontrei tratamento de fila local/retry no código — parece assumir conexão
presente a cada ação.*

---

## Leitura de QR code

**Já existe — o rascunho estava desatualizado.** Botão "Ler QR", biblioteca
`jsQR` (carregada por CDN), câmera do celular. Chama a mesma
`checkin_registrar`/`jantar_checkin_registrar` da busca por nome, só que
identificando a pessoa pelo conteúdo do QR em vez de digitar o nome.

Comentário no próprio código confirma o limite do rascunho que segue válido:
**"QR só vale pro check-in geral — o de jantar usa `convidado_id`, outro
identificador, e não tem crachá com QR pra ler."** Ou seja, a leitura por QR
funciona no check-in do evento grande; no check-in de jantar avulso, a busca
continua sendo só por nome.

*A confirmar se o QR do crachá é opaco (sem dado exposto no impresso) — não
verifiquei o formato do conteúdo codificado nem o gerador do crachá nesta
passagem.*

Presença **por atividade** (mesmo leitor QR, contexto diferente, descrita como
módulo futuro no rascunho) segue não encontrada em `checkin.html` — a tabela
`atividades` e a coluna `checkins.atividade_id` existem no schema (ver
`70-modelo-de-dados.md`), mas não há tela que crie uma atividade nem que
troque o contexto do leitor. Backend pronto, front não construído — mover
para `60-modulos-previstos.md` com essa ressalva, não para cá.

---

## Perguntas do rascunho, respondidas pelo código

- **A tela registra quem fez o check-in?** Sim — `checkins.registrado_por`.
- **Há desfazer, e quem pode usá-lo?** Sim, visível por linha. "Quem pode":
  mesma exigência de `_exige_staff()` do resto da tela — qualquer staff ativo,
  não um papel à parte.
- **Como o staff faz login no dia?** Mesmo mecanismo do resto do sistema
  (magic link ou senha, sessão do Supabase Auth) — não há modo de "acesso
  compartilhado no aparelho" no código; se isso acontece na prática (um
  celular, uma sessão, vários operadores), é decisão operacional, não algo
  que a tela distingue.

## A confirmar com o organizador

- A tela cruza pendência financeira/contrato no momento do check-in, ou só
  identificação?
- Comportamento com internet instável — não há fila local nem retry
  encontrado.
- O que a tela mostra, especificamente, para acompanhante e para criança
  (categoria de crachá é resolvida por `v_etiquetas`/`v_esperados`, mas não
  conferi a tela renderizando esse diferencial linha a linha).
- Se o QR do crachá é de fato opaco.
