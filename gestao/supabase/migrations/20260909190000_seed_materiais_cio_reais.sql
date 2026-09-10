-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Bloco 5.4 — os dois links reais do catalogo de fornecedores e da
-- revista, informados pelo organizador. Entram direto por migration
-- (em vez de exigir que alguem preencha pelo admin.html na mao) —
-- ficam disponiveis pra area do CIO assim que esta migration rodar.
-- =====================================================================

set search_path = gestao, public;

insert into materiais_cio (tipo, titulo, url, ordem, ativo)
select 'catalogo', 'Catálogo de fornecedores CIO Cerrado', 'https://ciocerrado.com.br/network/', 1, true
where not exists (select 1 from materiais_cio where url = 'https://ciocerrado.com.br/network/');

insert into materiais_cio (tipo, titulo, url, ordem, ativo)
select 'revista', 'Revista CIO Cerrado', 'https://heyzine.com/flip-book/27dd32c191', 1, true
where not exists (select 1 from materiais_cio where url = 'https://heyzine.com/flip-book/27dd32c191');
