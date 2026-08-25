# Testes de comportamento

Rodam contra o banco **local**, depois de `supabase db reset`.

```bash
docker exec -i supabase_db_gestao-cio-cerrado psql -U postgres -d postgres -q \
  < supabase/tests/01-cenario-setup.sql
```

Ordem: `01` monta o cenário (evento aberto, duas patrocinadoras em cotas
diferentes, quartos, um CIO com contrato assinado), `02` exercita portal
e rooming, `03` exercita a fila da mesa redonda, `04` a fatura
complementar e `05` a reserva da indicação com prazo por cota.

`03` e `05` **não rodam juntos**: os dois criam mesa redonda para as
mesmas empresas e `sessoes` não tem chave única, então rodar os dois
duplica as mesas. Escolha um por `db reset`.

## Por que eles trocam de papel

```sql
set role authenticated;
set request.jwt.claims = '{"email":"ana@alfa.test","role":"authenticated"}';
```

É o que o PostgREST faz a cada request. Sem isso `auth.jwt()` volta vazio,
tudo roda como superusuário e **todo teste de permissão passa por engano**.

## Cuidado ao escrever teste novo

Os ids precisam ser capturados com `\gset` **antes** do `set role`.

Isso era estilo e virou obrigação. Antes, um subselect rodando como Ana
voltava vazio pela RLS e o teste passava a medir a RLS em vez da função
— erro silencioso, que aconteceu nas duas primeiras versões destes
arquivos. Desde 25/08 o papel `authenticated` não tem acesso nenhum às
tabelas do schema (só RPC), então o mesmo subselect agora estoura com
`permission denied for table X`. Barulhento, o que é melhor.

Se o seu teste novo precisa de um id, pegue no topo, como postgres.

`01` não é idempotente na parte de `sessoes` (a tabela não tem chave
única), então rodar duas vezes cria mesas duplicadas. Dê `db reset` antes.
