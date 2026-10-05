-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Vincula 30 CIOs aleatorios (ja existentes no cadastro) ao evento de
-- teste "Teste da Ferramenta 2027" — pedido do organizador em
-- 29/09/2026, pra ter gente de verdade pra testar rooming/mesa
-- redonda/etc. sem depender de inscricao nova. Busca pelo NOME exato
-- (confirmado pelo organizador), nao pelo slug — o slug e' inferido
-- da URL nas capturas de tela (teste2027), sem confirmacao direta.
--
-- NAO E SCHEMA — sao linhas de dado, mesmo padrao ja usado em
-- 20260829150000_dados_teste_usabilidade.sql: INSERT direto, rodando
-- como superusuario, reproduzindo o shape de
-- admin_importar_participantes_sympla (participante aprovado direto,
-- sem passar pela funcao) — SET ROLE nao e confiavel no runner do
-- `db push` hospedado (achado documentado naquela mesma migration).
--
-- "Aleatorio no cadastro" = order by random() sobre TODOS os gestores
-- existentes, sem filtro de empresa/segmento/evento anterior — inclui
-- quem ja e participante de outro evento (gestor pode participar de
-- varios eventos, participantes e' chave (evento_id, gestor_id), nao
-- por gestor sozinho).
--
-- IDEMPOTENTE NO SENTIDO CERTO: rodar de novo nao troca quem ja foi
-- vinculado (on conflict do nothing) nem tenta completar pra 30 de
-- novo — e' um sorteio de uma vez so, nao uma meta a manter.
-- =====================================================================

set search_path = gestao, public;

do $$
declare v_evento_id uuid; v_vinculados int;
begin
  select id into v_evento_id from eventos where nome = 'Teste da Ferramenta 2027';
  if v_evento_id is null then
    -- 05/10/2026: num banco que nao tem esse dado (db reset do zero, ambiente
    -- de teste) pula em vez de abortar o historico inteiro. No hospedado
    -- esta migration ja rodou; isto nao muda nada la.
    raise notice 'Evento "Teste da Ferramenta 2027" nao encontrado (busca por nome exato) — confira o nome certo em admin.html (Estrutura) antes de rodar isto — pulando: este banco nao tem o dado que esta migration corrige';
    return;
  end if;

  insert into participantes (evento_id, gestor_id, status, origem, aprovado_em, aprovado_por)
  select v_evento_id, g.id, 'aprovado', 'manual', now(), 'seed-cios-teste-30'
  from (
    select id from gestores order by random() limit 30
  ) g
  on conflict (evento_id, gestor_id) do nothing;

  select count(*) into v_vinculados from participantes
   where evento_id = v_evento_id and aprovado_por = 'seed-cios-teste-30';

  raise notice '% CIO(s) vinculado(s) ao evento "Teste da Ferramenta 2027" por este seed.', v_vinculados;
end $$;
