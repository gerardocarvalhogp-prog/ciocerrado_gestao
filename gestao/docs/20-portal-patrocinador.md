# Portal do patrocinador — `portal.html?evento=`

Área onde a empresa patrocinadora administra a própria cota. É a face do evento
para quem está pagando por ele: acabamento e clareza aqui valem tanto quanto
função.

Acesso por magic link, com opção de criar senha. **Uma empresa pode ter vários
usuários com login**, todos com a mesma visão dos dados da empresa — modelado
em `usuarios_patrocinador`, sem limite de linhas por `patrocinador_id`.

**Sete abas**, não cinco: Quartos, Mesa redonda, Indicações, Brindes,
**Convidados**, Financeiro, **Manual** — as duas em negrito não estavam no
rascunho.

---

## Regra crítica: isolamento

Conferido em `70-modelo-de-dados.md`, seção "Acesso e isolamento": nenhuma das
21 funções `patro_*` chamadas por esta tela devolve dado sem checar
`_exige_patrocinador`/`meus_patrocinadores()` primeiro — inclusive quando a
própria tela manda `p_patrocinador_id` como parâmetro (o que o cliente manda
não é confiado; a função confere de novo do lado do servidor, contra o e-mail
do JWT).

O patrocinador vê exclusivamente os dados da própria empresa. Confirmado nas
sete abas — nenhuma delas expõe e-mail nem telefone de convidado que a própria
empresa não tenha ela mesma escolhido (ver aba Convidados, abaixo).

---

## Abas

### Quartos

Quartos que a cota dá direito, e o quarto extra à parte.

- Cartão por quarto, com ocupante(s), CPF, e transfer por pessoa (cada
  ocupante do mesmo quarto pode sair de origem diferente — GYN ou BSB).
- **Quarto adicional gera cobrança, confirmada antes de reservar**: o bloco
  "Quartos disponíveis" mostra disponibilidade em tempo real por tipo, com
  preço; clicar em "Reservar" abre uma confirmação explícita com o valor
  ("Custo: R$ X, que entra na sua fatura") antes de qualquer coisa ser criada.
  Isso responde a pergunta represada do rascunho.
- Quarto extra pode ser cancelado pelo próprio portal — volta para a
  disponibilidade do hotel.

**Sobre o gotcha da planilha antiga** (campo de associação preenchido com nome
da empresa em vez do número): não se aplica mais como risco — o portal não tem
nenhum campo de "escolha sua empresa"; a identidade vem do login
(`PATRO.patrocinador_id`), não de entrada livre. O problema era do processo em
planilha; a tela atual não reabre esse buraco.

### Mesa redonda

Vagas de convidado que a cota dá direito, dentro de uma fila de escolha por
`sessao`.

- Fila por `ordem_prioridade` da cota (Esmeralda → Prata) — `v_ordem_escolha`.
- Vaga não pode exceder a cota: `patro_escolher_convidados` recusa
  (`'Cota de % vaga(s); voce ja tem % e tentou somar %'`) — **bloqueio, não
  aviso nem cobrança automática.**
- Prazo por vez na fila: passado o prazo da cota, a vez passa para a próxima
  (`'O prazo da sua cota terminou em %...'`) — mensagem visível na tela
  (`notaPrazo`).
- Convidado não se repete em outra sessão do mesmo tipo (mesma checagem de
  `70-modelo-de-dados.md`).

*A confirmar: em que momento a lista final da mesa é considerada liberada
para o patrocinador — não encontrei um estado explícito de "lista fechada"
nesta aba, só o prazo da fila de escolha.*

### Indicações (rótulo do rascunho: "Indicar CIO")

Formulário simples (nome, empresa, cargo, e-mail, telefone, observação) — só
nome é obrigatório.

**Status da indicação, visível ao patrocinador, confirmado no código:**
`nova` ("Aguardando convite"), `convidado` ("Convidado"), `inscrito`
("Inscrito"), `recusado` ("Não seguiu"), `duplicado` ("Já na base"). Isto
responde a pergunta represada do rascunho — o portal acompanha, sim, o status,
com esses cinco rótulos.

### Brindes

Um formulário por empresa, não por quarto — texto explícito na tela: *"Um
brinde por empresa, não um por quarto."*

**Coletado, confirmado no código:** descrição, quantidade, destino (`stand`
ou `quarto` — entregar no quarto dos convidados custa mais, valor mostrado na
tela) e, depois de marcado "vamos levar", transportadora + código de rastreio.
**Não coletado:** data de entrega, dimensões, imagem. **Não encontrado:** prazo
limite explícito nesta aba.

### Convidados

**Não estava no rascunho.** Lista consolidada de quem a empresa efetivamente
tem confirmado — só quem está **aprovado E com contrato assinado**
(`patro_convidados_confirmados`). Comentário no próprio código explica a
decisão de design: presença ainda não confirmada não deveria aparecer como se
fosse, e a lista **não traz e-mail nem telefone** de propósito — contato só
depois de o patrocinador efetivamente escolher o convidado (mailing da
sessão), não antes.

### Financeiro

**Não é fatura de cota** — é `patro_minha_fatura`, os itens adicionais
(quarto extra, brinde no quarto etc.) que a empresa gerou, com total,
vencimento, data de pagamento se já paga, e observação da organização.
Estados `estimada` (muda sozinha se o patrocinador mexer em quarto/brinde) e
fechado (organização travou o valor).

**Confirmado: não há nota fiscal, boleto nem comprovante no portal — só
status e itens discriminados.** Texto na própria tela orienta "fale com a
organização" para dúvida de lançamento.

*Isto não cobre o valor da cota em si — só adicionais. Se a cota tem tela de
pagamento própria em algum outro lugar, não encontrei nesta aba.*

### Manual

**Não estava no rascunho.** Nome, local, datas do evento e os prazos que
afetam o CIO inscrito por essa empresa (prazo de contrato, de rooming, de
cancelamento) — informativo, sem ação.

---

## Padrão de acabamento esperado

O portal é avaliado por gerentes de marketing de multinacional. Contam como
defeito reportável, não como implicância:

- formatação inconsistente de valor (`R$ 1.500` vs `1500,00`)
- formatação inconsistente de data (`12/08/2026` vs `2026-08-12`)
- mistura de português e inglês na mesma tela
- rótulos que mudam de nome entre abas para a mesma coisa
- estados vazios sem explicação ("nada aqui" sem dizer o que fazer)
- comportamento diferente no celular

*Não verificado nesta passagem — exige uso da tela, não leitura de código.*

---

## Perguntas do rascunho, respondidas pelo código

- **O patrocinador pode pedir quarto adicional pelo portal, e isso gera
  cobrança automática?** Sim, com confirmação explícita do valor antes de
  reservar.
- **O que acontece quando excede o limite da cota (mesa redonda)?**
  Bloqueio — a função recusa com mensagem, não aceita e cobra.
- **O patrocinador acompanha o status da indicação?** Sim, cinco estados
  visíveis.
- **O que é coletado em Brindes?** Descrição, quantidade, destino, rastreio —
  sem data de entrega, dimensões nem imagem.
- **Há nota fiscal/boleto/comprovante no Financeiro?** Não — só status e
  itens.

## A confirmar com o organizador

- Como um segundo usuário da mesma empresa é criado — não encontrei tela de
  autoatendimento para isso em `portal.html`; parece ser só pelo admin.
- Em que momento a lista de mesa redonda é considerada "liberada" para o
  patrocinador ver o resultado final.
- Se existe prazo de corte por aba além do prazo de fila da mesa redonda — não
  encontrei um bloqueio geral de edição por data nas demais abas.
- **O patrocinador consegue exportar a própria lista?** Não encontrei nenhuma
  chamada de exportação em `portal.html` — se existe, não é nesta tela.
- Existe registro visível (na tela, não só no banco) de quando cada dado foi
  salvo e por qual usuário, quando há mais de um login na mesma empresa?
- Onde a cota em si é paga/registrada — a aba Financeiro cobre só adicionais.
