# Área do CIO convidado — `rooming.html?evento=`

Área do executivo convidado. Acesso por magic link, com opção de criar senha —
mesmo mecanismo do resto do sistema. Identidade resolvida por
`_meu_participante(p_evento_slug)`: uma linha em `participantes` cujo
`gestores.email_norm` bate com o e-mail logado, dentro do evento do slug —
ver `70-modelo-de-dados.md`.

O público é sistemático e detalhista: lê tudo antes de preencher, confere valor
por valor e não aceita ambiguidade em nada que envolva dinheiro ou compromisso.
Clareza vale mais que economia de cliques.

---

## Quem ainda não tem inscrição: "Quero participar"

Tela de autocadastro (`part_autocadastro`) para quem chega sem convite prévio
— nome e e-mail obrigatórios, resto opcional. Não duplica: se o e-mail já
tem inscrição no evento, devolve o status existente em vez de criar de novo.
Se o evento não está com `status='aberto'`, recusa educadamente
("as inscrições... estão fechadas") em vez de erro técnico.

O cadastro entra como `participantes.status='pendente'` — mesma aprovação
humana do fluxo Sympla.

---

## Trilha (quem já está inscrito)

A tela principal mostra três etapas em sequência, cada uma travando a
seguinte: **Inscrição → Contrato → Dados de hospedagem.**

- **Inscrição**: aprovada / em análise / não aprovada — reflexo de
  `participantes.status`.
- **Contrato**: assinado / enviado (com prazo) / ainda não enviado — reflexo
  do Autentique (ver `80-integracoes.md`).
- **Dados de hospedagem**: só libera com inscrição aprovada **E** contrato
  assinado ao mesmo tempo — `rooming_liberado` em `part_meu_status` exige as
  duas condições juntas, não uma ou outra.

Antes da liberação, a tela mostra o link do contrato para assinar (se já
enviado) ou uma mensagem de espera. **Responde à pergunta represada do
rascunho:** "o que é editável pelo próprio CIO depois de assinado" — nada
antes do rooming abrir; a partir daí, só os campos de hospedagem abaixo. Não
encontrei tela de edição dos "dados próprios" (nome, empresa, cargo) vindos da
inscrição — parecem travados, sem formulário de autocorreção.

---

## Dados de hospedagem ("Quem vai com você")

O titular já está incluído automaticamente. O CIO adiciona acompanhante(s) e
filho(s) por um botão "+ Adicionar acompanhante" — mesmo formulário para os
dois, distinguidos por um campo `tipo` (`adulto`/`crianca`).

**Campos por pessoa:** nome (obrigatório), CPF, data de nascimento
(obrigatória só para `tipo='crianca'` — é o que define cobrança e regra de
crachá), transfer (usa/não usa) e, se usa, origem (Goiânia ou Brasília).
Transfer do titular é campo à parte, fora da lista de acompanhantes.

**Validações confirmadas na função (`part_salvar_rooming`), não só no front:**
- nome vazio é recusado;
- data de nascimento não pode ser depois do início do evento;
- criança sem data de nascimento é recusada — é o dado que decide cobrança e
  crachá, não pode ficar em aberto;
- origem de transfer só aceita `GYN` ou `BSB`;
- quantidade de gente no quarto (titular + acompanhantes) não pode passar da
  capacidade do quarto — acima disso a mensagem já orienta: **"quarto
  adicional"**;
- fora do prazo de rooming do evento, só staff consegue salvar — CIO recebe
  erro claro do prazo encerrado.

**Regra do valor aparecer antes da confirmação — confirmada:** a cada campo
alterado, `part_previa_fatura` recalcula e mostra o resumo na mesma tela,
antes de clicar em "Confirmar dados". Salvar dispara
`part_calcular_fatura` e devolve o total fechado.

**Ao salvar com sucesso**, o sistema enfileira uma notificação
(`notificacoes`, tipo `rooming_ok`) — existe confirmação por e-mail do
preenchimento, sujeita à mesma ressalva de entrega do Resend documentada em
`80-integracoes.md`.

---

## Check-in / check-out com noite extra — não encontrado

**O rascunho descreve uma funcionalidade que não existe no código lido.** Não
há campo de data de entrada/saída no hotel em `rooming.html`, nem cálculo de
"noite extra" em `part_previa_fatura`/`part_calcular_fatura`. As datas de
hospedagem parecem fixas pelo período do evento (`eventos.data_inicio`/
`data_fim`), sem escolha do hóspede. Se essa regra existe, é fora desta tela —
ver `PERGUNTAS.md`.

---

## Fatura adicional

`part_minha_fatura` devolve a fatura mais relevante (emitida antes de paga,
paga antes de qualquer outra, ignorando cancelada), com **itens
discriminados** (`fatura_itens`: descrição, quantidade, valor unitário, valor
total) — responde à exigência do rascunho de extrato item a item.

*A confirmar: pagamento pelo sistema ou fora dele — não encontrei RPC de
pagamento nem gateway integrado nesta tela; parece que o CIO só visualiza o
que deve, sem pagar por aqui.*

---

## Comportamento do formulário — conferido contra os quatro pontos do rascunho

| Exigência | Situação |
|---|---|
| Salvamento parcial preservado entre sessões | Parcial — o formulário carrega o que já existe (`part_listar_rooming`), mas cada visita recomeça do que foi salvo pela última vez; não há rascunho de campo-a-campo não salvo. |
| Confirmação explícita do que foi salvo | Sim — aviso de sucesso após `part_salvar_rooming`, mais a fatura recalculada na tela. |
| Nenhum campo obrigatório sem indicação prévia | Não verificado linha a linha nesta passagem — exige inspeção visual da tela, não só do código. |
| Sessão expirada não descarta o digitado | Não encontrado tratamento específico — perda de sessão no meio do preenchimento provavelmente perde o que não foi salvo, como em formulário web comum. |

---

## Etapas que não se aplicam (jantar)

Convidado de jantar avulso não passa por `rooming.html` — a confirmação de
presença dele é tratada inteiramente dentro de `jantares.html`
(`jantar_convidados.status`), sem rooming, transfer, filho nem mesa redonda.
Ver `50-jantares.md`.

---

## A confirmar com o organizador

- Regra de check-in/check-out com noite extra: existe em algum lugar, ou o
  rascunho descrevia um plano que não foi construído desta forma?
- Há prazo de corte separado para alterar rooming depois de já preenchido uma
  vez, além do prazo geral do evento?
- Como o CIO pede algo fora do padrão (chegada antecipada, pedido especial) —
  não encontrei campo de observação livre nesta tela.
- Valores atuais de acompanhante, criança por faixa de idade, e se existe
  cobrança de "noite extra" (ver achado acima).
- Pagamento da fatura acontece pelo sistema ou fora dele.
