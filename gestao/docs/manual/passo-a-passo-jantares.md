# Passo a passo — Tela de Jantares

Guia operacional de `jantares.html`. Complementa o capítulo 6 do
[Manual do Sistema](Manual_Sistema_Gestao_CIO_Cerrado.docx) — aqui o foco é
"o que clicar, em que ordem", não a explicação conceitual.

Conferido contra o código em 2026-09-02. Acesso: só organização (sócios e
analista) — quem estiver logado como staff comum não opera esta tela.

---

## 1. Como entrar

Acesse `ciocerrado.netlify.app/gestao/jantares.html` e entre com seu e-mail
— por link mágico (recebido por e-mail) ou por senha, se você já tiver
criado uma. A tela abre direto na aba **Agenda**, com a lista de todos os
jantares já cadastrados.

---

## 2. Criar um jantar novo

Na aba **Agenda**, o formulário **"Novo jantar"** pede:

| Campo | O que colocar |
|---|---|
| Patrocinador | Nome da empresa que está oferecendo o jantar — texto livre, não precisa já estar cadastrada em nenhum outro lugar do sistema |
| Site | Site da empresa (opcional — ajuda a IA a entender o que ela vende, se você for usar a curadoria por aderência) |
| Data | Data do jantar |
| Horário | Ex.: `20:00` |
| Local | Onde vai acontecer |
| Capacidade | Quantas pessoas cabem à mesa |
| Perfil de convidado desejado | Uma linha livre — ex.: "CIOs de varejo e indústria" |
| Observações | Qualquer nota interna |

Clique em **"Criar jantar"**. Ele aparece na lista da Agenda, e você pode
clicar em **"Abrir"** para entrar na ficha dele.

---

## 3. Editar os dados de um jantar já criado

Dentro da ficha do jantar, o bloco **"Dados do jantar"** tem os mesmos
campos do cadastro, mais:

- **Status** do jantar, num seletor no topo da ficha;
- **Link do Sympla** — se você tiver criado uma página de inscrição no
  Sympla para esse jantar, cole o link aqui. É o mesmo link que aparece
  depois no bloco de importar convidados.

Depois de mexer em qualquer campo, clique em **"Salvar"**.

---

## 4. Adicionar convidados — quatro caminhos

Dentro da ficha do jantar, role até os blocos abaixo. Eles não são
excludentes — dá para combinar mais de um no mesmo jantar.

### 4.1 Importar do Sympla

Se o jantar tem inscrição pelo Sympla, exporte a planilha de inscritos do
painel do Sympla e suba o arquivo (`.xlsx` ou `.csv`) em **"Importar
convidados do Sympla"**. Clique em **"Importar convidados"**. Quem já
estava na lista é atualizado, não duplicado.

### 4.2 Buscar no cadastro

Para quando você já sabe quem quer chamar. Em **"Buscar no cadastro"**:

1. Digite um nome ou empresa no campo de busca, e/ou marque um ou mais
   valores nos filtros de **Perfil**, **Segmento**, **Cidade** e **UF**
   (segure Ctrl para marcar mais de um em cada filtro).
2. Clique em **"Buscar"**.
3. Na lista de resultado, marque quem você quer (checkbox por linha, ou
   "Marcar todos os N visíveis").
4. Clique em **"Adicionar selecionados"**.

### 4.3 Sugerir convidados por aderência (inteligência artificial)

Para quando você ainda não sabe quem chamar, e quer que o sistema
pesquise o patrocinador e aponte quem da base combina melhor com ele.

1. Ajuste os filtros: abrangência geográfica, faturamento mínimo,
   quantos executivos por empresa, se inclui híbridas, se exclui
   fornecedores, se exclui quem já foi convidado antes.
2. Clique em **"Analisar"**. A busca demora um pouco — ela pesquisa o
   patrocinador na internet antes de pontuar cada empresa da base.
3. Revise a lista de sugestões e escolha quem entra.

### 4.4 Adicionar quem não passou pela análise

Para equipe própria ou um convidado de última hora, fora da base.
Preencha nome, empresa, e-mail, telefone, cargo e a identificação
(Equipe CIO Cerrado / Patrocinador / Convidado) e clique em
**"Adicionar"**. Entra já como confirmado.

---

## 5. Cuidar da lista de convidados

No bloco **"Convidados"**, cada pessoa tem botões de ação de acordo com o
status atual dela:

- **Confirmar** — marca como confirmado;
- **Compareceu** — marca como presente (normalmente isso acontece pelo
  check-in, não clicando aqui, mas dá para fazer manual);
- **Recusou** — marca como recusado;
- **Remover** — tira da lista deste jantar.

---

## 6. Etiquetas e crachás com QR

Dois botões no topo do bloco de Convidados:

- **"Etiquetas"** — gera a etiqueta simples (nome, empresa, cargo,
  identificação) de todo mundo que ainda não recusou.
- **"Imprimir crachás (QR)"** — gera o crachá com QR code, para ler na
  hora do check-in.

---

## 7. Exportar a lista (mailing)

Botão **"Exportar mailing"**. Se já houver algum check-in feito, o
sistema pergunta se você quer só quem compareceu ou todos os convidados.
A planilha sai com nome, cargo, empresa, segmento, cidade, UF, e-mail e
telefone (já formatado).

---

## 8. Fazer o check-in no dia

Clique em **"Abrir check-in"**, dentro da ficha do jantar — abre
`checkin.html` já escopado para aquele jantar específico. De lá, dá para
buscar por nome ou ler o QR do crachá para registrar a chegada. Ver o
capítulo 5 do Manual para o detalhe dessa tela.

---

## 9. Cancelar ou remover um jantar

Na ficha do jantar: **"Remover jantar"** apaga o cadastro. Na lista da
Agenda, jantares que não vão acontecer podem ser marcados como
cancelados em vez de apagados — útil para manter o histórico sem contar
como jantar realizado.

---

## 10. Sondagem — testar um patrocinador sem criar o jantar

Aba **Sondagem**, separada da Agenda. Roda a mesma análise de aderência
do item 4.3, mas sobre um patrocinador em potencial — sem criar jantar
nenhum, sem reservar capacidade. Serve para levar um número concreto
("temos X empresas com bom encaixe") para uma conversa comercial antes
de fechar. Se o jantar sair do papel, ele é criado na Agenda normalmente,
e a seleção é refeita lá.

---

## 11. Estatísticas — ler os números

Aba **Estatísticas**. Quatro blocos, cada um com botão de exportar:

| Bloco | O que mostra |
|---|---|
| Convidados sempre, confirmam nunca | 3+ convites, zero confirmações — candidatos a sair da lista, ou a trocar de contato na mesma empresa |
| Confirmaram e não apareceram | Confirmou presença, o jantar já aconteceu, o check-in nunca marcou a chegada |
| Quem é chamado com mais frequência | Ranking bruto de convites, com taxa de confirmação ao lado |
| Empresas que nunca foram convidadas | Candidatas para as próximas rodadas de prospecção |

A equipe do CIO Cerrado fica de fora desses rankings — ela comparece aos
próprios eventos que organiza, o que distorceria a leitura.

---

## Perguntas rápidas

**Um convidado pode ir a mais de um jantar?** Sim, sem trava nenhuma — é
até o motivo de existir a aba Estatísticas: mostrar quando isso está
acontecendo demais com a mesma pessoa.

**Dá para desfazer um check-in feito por engano?** Sim, pelo botão
"Desfazer" na própria tela de check-in (capítulo 5 do Manual).

**O patrocinador consegue ver a lista de convidados?** Não — jantares é
uma tela só de organização; o patrocinador do jantar não tem login nem
acesso a nenhuma parte desta tela.
