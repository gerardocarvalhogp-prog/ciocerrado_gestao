# Testes de comportamento

```bash
docker exec -i supabase_db_gestao-cio-cerrado psql -U postgres -d postgres -q \
  < supabase/tests/07-regras-de-dinheiro.sql
```

## Duas famílias, e a diferença importa

**`04` e `07` rodam em transação e desfazem tudo no fim.** Podem rodar
contra um banco com dado dentro, quantas vezes quiser, sem `db reset`.

**`01`, `02`, `03` e `05` gravam de verdade** e exigem banco limpo:
`supabase db reset`, depois `01` (que monta o cenário), depois o que
você quiser exercitar.

A diferença nasceu de um problema real: o banco local passou a ter a
importação do CADASTRO 2025, com 1056 gestores. Um `db reset` para rodar
teste destrói isso. Teste que só roda em banco vazio é teste que não
roda — daí a família nova.

Quando der, vale converter `01`–`03` e `05` para o mesmo formato.

## O que cada um cobre

| | |
|---|---|
| `01` | cenário base: evento aberto, duas patrocinadoras, quartos, um CIO com contrato |
| `02` | portal e rooming, e o que cada papel **não** pode fazer |
| `03` | fila da mesa redonda: ordem por cota, passar a vez, convidado que some da lista |
| `04` | fatura congelada: estimada acompanha o rooming, emitida e paga não |
| `05` | reserva da indicação e janela por cota |
| `07` | cortesia do acompanhante, teto de 4, transfer por pessoa, brinde da empresa e seu custo, preço do quarto adicional, correção do tipo de faixa |

`03` e `05` **não rodam juntos**: os dois criam mesa redonda para as
mesmas empresas e `sessoes` não tem chave única. `01` também não é
idempotente na parte de `sessoes`.

## Por que eles trocam de papel

```sql
set role authenticated;
set request.jwt.claims = '{"email":"ana@alfa.test","role":"authenticated"}';
```

É o que o PostgREST faz a cada request. Sem isso `auth.jwt()` volta
vazio, tudo roda como superusuário e **todo teste de permissão passa por
engano**.

## Cuidado ao escrever teste novo

**Os ids precisam ser capturados com `\gset` antes do `set role`.** Isso
era estilo e virou obrigação: antes, um subselect rodando como Ana
voltava vazio pela RLS e o teste passava a medir a RLS em vez da função —
erro silencioso. Desde 25/08 o papel `authenticated` não tem acesso
nenhum às tabelas do schema (só RPC), então o mesmo subselect estoura com
`permission denied for table X`. Barulhento, o que é melhor.

**Cada recusa esperada precisa do seu `savepoint`.** No Postgres o
primeiro erro aborta a transação inteira e todo comando seguinte devolve
"current transaction is aborted" — o resto do teste não roda e passa por
engano. O padrão é:

```sql
savepoint s1;
select funcao_que_deve_falhar(...);
rollback to s1;
```

## O que saiu daqui

`04-fatura-complementar.sql` e `06-brindes.sql` foram removidos em
26/08: os dois afirmavam comportamento que deixou de existir — a fatura
complementar virou fatura congelada, e o brinde por quarto virou brinde
por empresa. Teste que afirma o passado é pior que teste nenhum, porque
falha por motivo errado e faz procurar defeito onde não tem. A cobertura
foi para `04-fatura-congelada.sql` e para a seção 4 do `07`.
