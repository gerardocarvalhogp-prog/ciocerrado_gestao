# Testes de comportamento

Rodam contra o banco **local**, depois de `supabase db reset`.

```bash
docker exec -i supabase_db_gestao-cio-cerrado psql -U postgres -d postgres -q \
  < supabase/tests/01-cenario-setup.sql
```

Ordem: `01` monta o cenário (evento aberto, duas patrocinadoras em cotas
diferentes, quartos, um CIO com contrato assinado), `02` exercita portal
e rooming, `03` exercita a fila da mesa redonda.

## Por que eles trocam de papel

```sql
set role authenticated;
set request.jwt.claims = '{"email":"ana@alfa.test","role":"authenticated"}';
```

É o que o PostgREST faz a cada request. Sem isso `auth.jwt()` volta vazio,
tudo roda como superusuário e **todo teste de permissão passa por engano**.

## Cuidado ao escrever teste novo

Os ids precisam ser capturados com `\gset` **antes** do `set role`. As
tabelas são staff-only na RLS, então um subselect rodando como Ana volta
vazio e o teste passa a medir a RLS em vez da função — foi o que
aconteceu nas duas primeiras versões destes arquivos.

`01` não é idempotente na parte de `sessoes` (a tabela não tem chave
única), então rodar duas vezes cria mesas duplicadas. Dê `db reset` antes.
