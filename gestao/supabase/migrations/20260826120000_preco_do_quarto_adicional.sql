-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- A disponibilidade passa a dizer quanto custa.
--
-- O QUE ESTAVA ERRADO
--
-- A tabela "Quartos disponiveis" do portal mostrava tipo e quantos
-- livres, e um botao "Reservar". O preco nao aparecia em lugar nenhum:
-- o patrocinador clicava sem saber quanto ia custar e descobria depois,
-- na fatura.
--
-- `patro_disponibilidade` devolvia so (tipo, livres) — a tela nao tinha
-- de onde tirar o valor nem que quisesse.
--
-- Os precos ja existem, um por tipo (`quarto_single`, `quarto_duplo`,
-- `quarto_triplo`), configurados na aba Precos. So faltava mostra-los.
--
-- Tipo sem preco cadastrado volta zero, e a tela trata como "sob
-- consulta" em vez de escrever R$ 0,00 — dizer que e de graca seria pior
-- do que nao dizer nada.
-- =====================================================================

set search_path = gestao, public;

drop function if exists patro_disponibilidade(text);

create function patro_disponibilidade(p_evento_slug text)
returns table (tipo text, livres bigint, valor numeric)
language sql stable security definer
set search_path = gestao, public as $$
  select v.tipo, v.livres, _preco_item(e.id, 'quarto_' || v.tipo)
  from v_disponibilidade_quartos v
  join eventos e on e.id = v.evento_id
  where e.slug = p_evento_slug
  order by v.tipo;
$$;

revoke execute on function patro_disponibilidade(text) from public, anon;
grant execute on function patro_disponibilidade(text) to authenticated, service_role;
