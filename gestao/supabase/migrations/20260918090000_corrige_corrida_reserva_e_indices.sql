-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Dois achados da revisao de arquitetura de 10/09/2026 (P1), sem
-- relacao entre si alem de serem ambos migration-only:
--
-- 1. _garantir_reserva nao trava a linha antes do find-or-create —
--    duplo clique/retry de rede em part_salvar_rooming pode criar DUAS
--    reservas ativas pro mesmo participante. _recalcular_fatura_
--    participante (20260825110000) pega uma arbitraria (sem LIMIT/
--    ORDER BY) quando ha mais de uma — a outra fica fantasma, fora da
--    fatura e do rooming. Corrige com o mesmo padrao ja documentado no
--    CLAUDE.md ("reserva concorrente usa SELECT...FOR UPDATE na linha
--    do recurso") — so que aqui a linha do recurso e' o PARTICIPANTE,
--    nao a reserva (que ainda nao existe no momento do lock). Index
--    unico parcial e' cinto-e-suspensorio: garante o invariante mesmo
--    se algum caminho futuro inserir direto sem passar por esta funcao.
--
-- 2. Indices de suporte a FK filtradas com frequencia no codigo, sem
--    indice nenhum ate agora: faturas (a tabela financeira central,
--    sem NENHUM indice alem da PK), reservas.evento_id,
--    sessoes.patrocinador_id, indicacoes.evento_id/gestor_id,
--    contratos.participante_id. Irrelevante no volume de hoje, vira
--    scan sequencial em toda tela financeira com ~130 CIOs + 61
--    patrocinadores x itens por evento.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. _garantir_reserva — trava + indice unico
-- ---------------------------------------------------------------------

-- pode ja existir reserva duplicada de antes desta migration — sem
-- limpar, o CREATE UNIQUE INDEX abaixo falha. Mantem a mais antiga
-- (created_at menor), cancela as demais em vez de apagar (rastro).
update reservas r set status = 'cancelado'
 where r.participante_id is not null
   and r.status <> 'cancelado'
   and r.id <> (
     select r2.id from reservas r2
      where r2.participante_id = r.participante_id
        and r2.status <> 'cancelado'
      order by r2.created_at asc, r2.id asc
      limit 1
   );

create unique index if not exists reservas_participante_ativa_uk
  on reservas (participante_id)
  where status <> 'cancelado' and participante_id is not null;

create or replace function _garantir_reserva(p_participante_id uuid) returns uuid
    language plpgsql security definer
    set search_path to 'gestao', 'public'
    as $$
declare v_res uuid; v_evento uuid;
begin
  -- trava a linha do participante ate o fim da transacao chamadora —
  -- duas chamadas concorrentes pro mesmo participante serializam aqui,
  -- a segunda so' prossegue depois que a primeira ja' commitou a
  -- reserva (e entao acha a reserva no SELECT abaixo, nao cria outra)
  perform 1 from participantes where id = p_participante_id for update;

  select id into v_res from reservas
   where participante_id = p_participante_id and status <> 'cancelado';

  if v_res is not null then return v_res; end if;

  select evento_id into v_evento from participantes where id = p_participante_id;

  insert into reservas (evento_id, participante_id, rotulo, tipo, origem, status)
  values (v_evento, p_participante_id, 'Hospedagem', 'duplo', 'inscricao', 'rascunho')
  returning id into v_res;

  return v_res;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Indices faltando
-- ---------------------------------------------------------------------

create index if not exists faturas_evento_status_ix on faturas(evento_id, status);
create index if not exists faturas_participante_ix on faturas(participante_id) where participante_id is not null;
create index if not exists faturas_patrocinador_ix on faturas(patrocinador_id) where patrocinador_id is not null;

create index if not exists reservas_evento_ix on reservas(evento_id);
create index if not exists sessoes_patrocinador_ix on sessoes(patrocinador_id);
create index if not exists indicacoes_evento_ix on indicacoes(evento_id);
create index if not exists indicacoes_gestor_ix on indicacoes(gestor_id) where gestor_id is not null;
create index if not exists contratos_participante_ix on contratos(participante_id);
