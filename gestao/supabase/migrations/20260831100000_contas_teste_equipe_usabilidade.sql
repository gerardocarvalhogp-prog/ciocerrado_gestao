-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- 16 contas de teste (4 pessoas x 4 perfis) pro evento
-- usabilidade-teste, com prefixo [TESTE] pra localizar e limpar depois.
--
-- Isto so cria a PONTA gestao (papel/associacao): admins (admin+staff),
-- usuarios_patrocinador e gestores+participantes. O login em si (senha,
-- confirmado) e feito a parte pela Admin Auth API — ver
-- supabase/functions/seed-contas-teste-equipe/index.ts — porque essa
-- parte nao roda via SQL de migration (auth.users nao se popula de
-- forma confiavel por INSERT direto; precisa da API que faz o hash de
-- senha certo). As duas partes usam a MESMA lista de e-mails.
--
-- ATENCAO — nao e possivel restringir admin/staff ao evento de teste:
-- a tabela admins e global por decisao ja fechada do projeto (README:
-- "admins globais", sem coluna de evento). As 4 contas +admin e as 4
-- +staff terao acesso de admin/staff de verdade a TODOS os eventos,
-- nao so ao de teste — mesmo comportamento da conta de teste unica
-- que ja existe hoje (gerardocarvalhogp+admin@gmail.com). Patrocinador
-- e CIO, essas sim, ficam presas ao evento/empresa de teste porque
-- essas tabelas sao escopadas por natureza.
--
-- Idempotente: cada bloco faz upsert pela chave natural (email_norm
-- em admins/gestores, patrocinador_id+email_norm em
-- usuarios_patrocinador, evento_id+gestor_id em participantes) — rodar
-- duas vezes atualiza, nao duplica.
-- =====================================================================

set search_path = gestao, public;

do $$
declare
  v_evento_id uuid;
  v_patro_id  uuid;
begin
  select id into v_evento_id from eventos where slug = 'usabilidade-teste';
  if v_evento_id is null then
    raise exception 'Evento usabilidade-teste nao encontrado — abortando, nada foi gravado';
  end if;

  select id into v_patro_id from patrocinadores
   where evento_id = v_evento_id and empresa = 'Empresa Teste Cowork';
  if v_patro_id is null then
    raise exception 'Patrocinador "Empresa Teste Cowork" nao encontrado no evento de teste — abortando, nada foi gravado';
  end if;

  -- ---------------------------------------------------------------
  -- admin + staff (8 linhas) — globais, ver aviso acima
  -- ---------------------------------------------------------------
  insert into admins (email, nome, role, ativo) values
    ('tacio.henrique+admin@ciocerrado.com.br',  '[TESTE] Tácio Henrique',          'admin', true),
    ('tacio.henrique+staff@ciocerrado.com.br',  '[TESTE] Tácio Henrique',          'staff', true),
    ('kelson.duarte+admin@ciocerrado.com.br',   '[TESTE] Kelson Duarte',           'admin', true),
    ('kelson.duarte+staff@ciocerrado.com.br',   '[TESTE] Kelson Duarte',           'staff', true),
    ('amarildo.moraes+admin@ciocerrado.com.br', '[TESTE] Amarildo Moraes',         'admin', true),
    ('amarildo.moraes+staff@ciocerrado.com.br', '[TESTE] Amarildo Moraes',         'staff', true),
    ('comunicacao+admin@ciocerrado.com.br',     '[TESTE] Fernanda (Comunicação)',  'admin', true),
    ('comunicacao+staff@ciocerrado.com.br',     '[TESTE] Fernanda (Comunicação)',  'staff', true)
  on conflict (email_norm) do update
    set nome = excluded.nome, role = excluded.role, ativo = true;

  -- ---------------------------------------------------------------
  -- patrocinador (4 linhas) — presas a "Empresa Teste Cowork" neste evento
  -- ---------------------------------------------------------------
  insert into usuarios_patrocinador (patrocinador_id, email, nome, ativo) values
    (v_patro_id, 'tacio.henrique+patrocinador@ciocerrado.com.br',  '[TESTE] Tácio Henrique',          true),
    (v_patro_id, 'kelson.duarte+patrocinador@ciocerrado.com.br',   '[TESTE] Kelson Duarte',           true),
    (v_patro_id, 'amarildo.moraes+patrocinador@ciocerrado.com.br', '[TESTE] Amarildo Moraes',         true),
    (v_patro_id, 'comunicacao+patrocinador@ciocerrado.com.br',     '[TESTE] Fernanda (Comunicação)',  true)
  on conflict (patrocinador_id, email_norm) do update
    set nome = excluded.nome, ativo = true;

  -- ---------------------------------------------------------------
  -- CIO convidado (4 linhas) — presas ao evento de teste
  -- ---------------------------------------------------------------
  with novos_gestores as (
    insert into gestores (nome, email, origem) values
      ('[TESTE] Tácio Henrique',         'tacio.henrique+cio@ciocerrado.com.br',  'manual'),
      ('[TESTE] Kelson Duarte',          'kelson.duarte+cio@ciocerrado.com.br',   'manual'),
      ('[TESTE] Amarildo Moraes',        'amarildo.moraes+cio@ciocerrado.com.br', 'manual'),
      ('[TESTE] Fernanda (Comunicação)', 'comunicacao+cio@ciocerrado.com.br',     'manual')
    on conflict (email_norm) do update set nome = excluded.nome
    returning id
  )
  insert into participantes (evento_id, gestor_id, status, origem)
  select v_evento_id, ng.id, 'aprovado', 'manual' from novos_gestores ng
  on conflict (evento_id, gestor_id) do update set status = 'aprovado';

end $$;
