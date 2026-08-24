-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- funcoes-admin.sql  ·  operacao do evento
--
-- Roda DEPOIS de schema.sql, schema-extra.sql, funcoes-patro.sql e
-- funcoes-part.sql.
--
-- Cobre: aprovacoes, indicacoes, importacao da base, fila de sugestoes,
-- alocacao de quartos, etiquetas, sessoes e o match de convidados.
--
-- Papeis: 'admin' para cadastro e decisao; 'staff' basta para a
-- operacao do dia (alocar quarto, imprimir etiqueta). E o mesmo corte
-- que o sistema de massagem ja usa.
-- =====================================================================

set search_path = gestao, public;

-- =====================================================================
-- 0. HELPERS
-- =====================================================================

create or replace function exigir_admin()
returns void language plpgsql stable security definer set search_path = gestao, public as $$
begin
  if not is_admin() then
    raise exception 'Acao restrita a administradores.';
  end if;
end;
$$;

create or replace function exigir_staff()
returns void language plpgsql stable security definer set search_path = gestao, public as $$
begin
  if not is_staff() then
    raise exception 'Acao restrita a equipe.';
  end if;
end;
$$;


-- Registra no historico do gestor toda troca de campo relevante. E o
-- que alimenta a deteccao de "esse CIO mudou de empresa".
create or replace function registrar_hist_gestor(
  p_gestor_id uuid, p_campo text, p_antigo text, p_novo text, p_por text
)
returns void language sql security definer set search_path = gestao, public as $$
  insert into gestores_historico (gestor_id, campo, valor_antigo, valor_novo, detectado_por)
  select p_gestor_id, p_campo, p_antigo, p_novo, coalesce(p_por,'manual')
  where coalesce(p_antigo,'') is distinct from coalesce(p_novo,'');
$$;

-- =====================================================================
-- 1. APROVACOES E INDICACOES
-- =====================================================================

create or replace function admin_listar_pendentes(p_evento_slug text)
returns table (
  participante_id uuid, nome text, cargo text, empresa text,
  email text, telefone text, origem text, indicado_por text,
  created_at timestamptz
)
language plpgsql stable security definer set search_path = gestao, public as $$
begin
  perform exigir_admin();
  return query
  select pa.id, g.nome, g.cargo, g.empresa, g.email, g.telefone,
         pa.origem, pt.empresa, pa.created_at
  from participantes pa
  join gestores g on g.id = pa.gestor_id
  left join patrocinadores pt on pt.id = pa.indicado_por_patrocinador_id
  where pa.evento_id = evento_id_por_slug(p_evento_slug)
    and pa.status = 'pendente'
  order by pa.created_at;
end;
$$;

-- Aprovar enfileira o contrato; recusar nao apaga nada. O disparo do
-- e-mail e do Autentique fica com integracao.py, que le a fila.
create or replace function admin_aprovar_participante(
  p_participante_id uuid, p_aprovado boolean
)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare
  r record;
  v_quem text := auth.jwt() ->> 'email';
begin
  perform exigir_admin();

  select pa.id, pa.evento_id, pa.status, g.email, g.nome
  into r
  from participantes pa join gestores g on g.id = pa.gestor_id
  where pa.id = p_participante_id;

  if r.id is null then raise exception 'Participante nao encontrado.'; end if;

  update participantes
     set status      = case when p_aprovado then 'aprovado' else 'recusado' end,
         aprovado_em = now(),
         aprovado_por= v_quem
   where id = p_participante_id;

  if p_aprovado then
    -- o contrato nasce aqui, ainda nao enviado: quem envia e a rotina
    insert into contratos (participante_id, status)
    values (p_participante_id, 'nao_enviado')
    on conflict (participante_id) do nothing;

    insert into notificacoes (evento_id, destinatario, tipo, assunto)
    values (r.evento_id, r.email, 'inscricao_aprovada', 'Sua inscricao foi aprovada');
  end if;

  return jsonb_build_object('ok', true, 'status',
    case when p_aprovado then 'aprovado' else 'recusado' end);
end;
$$;

create or replace function admin_listar_indicacoes(
  p_evento_slug text, p_status text default null
)
returns table (
  indicacao_id uuid, nome text, cargo text, empresa text,
  email text, telefone text, observacao text, status text,
  patrocinador text, created_at timestamptz
)
language plpgsql stable security definer set search_path = gestao, public as $$
begin
  perform exigir_admin();
  return query
  select i.id, i.nome, i.cargo, i.empresa, i.email, i.telefone,
         i.observacao, i.status, pt.empresa, i.created_at
  from indicacoes i
  join patrocinadores pt on pt.id = i.patrocinador_id
  where i.evento_id = evento_id_por_slug(p_evento_slug)
    and (p_status is null or i.status = p_status)
  order by i.created_at desc;
end;
$$;

-- Transforma a indicacao em inscricao pendente.
--
-- Entra como 'pendente', nao aprovada: indicacao de patrocinador e
-- sugestao, nao decisao. Guarda quem indicou, que e o que garante a
-- primeira camada da alocacao de mesa (indicacao direta).
create or replace function admin_converter_indicacao(p_indicacao_id uuid)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare
  i record;
  v_gestor uuid;
  v_part uuid;
  v_novo boolean := false;
begin
  perform exigir_admin();

  select * into i from indicacoes where id = p_indicacao_id for update;
  if i.id is null then raise exception 'Indicacao nao encontrada.'; end if;
  if nullif(trim(coalesce(i.email,'')),'') is null then
    raise exception 'Indicacao sem e-mail: nao da para criar inscricao.';
  end if;

  select id into v_gestor from gestores where email_norm = norm_doc(i.email);

  if v_gestor is null then
    insert into gestores (nome, email, telefone, cargo, empresa, origem)
    values (i.nome, i.email, i.telefone, i.cargo, i.empresa, 'indicacao')
    returning id into v_gestor;
    v_novo := true;
  end if;

  select id into v_part from participantes
  where evento_id = i.evento_id and gestor_id = v_gestor;

  if v_part is null then
    insert into participantes (evento_id, gestor_id, status, origem,
                               indicado_por_patrocinador_id)
    values (i.evento_id, v_gestor, 'pendente', 'indicacao', i.patrocinador_id)
    returning id into v_part;
  else
    -- ja inscrito por conta propria: so carimba quem indicou
    update participantes
       set indicado_por_patrocinador_id =
             coalesce(indicado_por_patrocinador_id, i.patrocinador_id)
     where id = v_part;
  end if;

  update indicacoes
     set status = 'convidado', gestor_id = v_gestor
   where id = p_indicacao_id;

  return jsonb_build_object('ok', true, 'participante_id', v_part,
                            'gestor_novo', v_novo);
end;
$$;

-- =====================================================================
-- 2. IMPORTACAO DA BASE DE GESTORES
-- =====================================================================


-- =====================================================================
-- 3. FILA DE SUGESTOES DA IA
-- =====================================================================

create or replace function admin_listar_sugestoes(p_status text default 'pendente')
returns table (
  id uuid, tipo text, gestor_nome text, empresa text, campo text,
  valor_atual text, valor_sugerido text, confianca numeric,
  fonte text, justificativa text, created_at timestamptz
)
language plpgsql stable security definer set search_path = gestao, public as $$
begin
  perform exigir_admin();
  return query
  select s.id, s.tipo, g.nome, s.empresa, s.campo,
         s.valor_atual, s.valor_sugerido, s.confianca,
         s.fonte, s.justificativa, s.created_at
  from sugestoes_ia s
  left join gestores g on g.id = s.gestor_id
  where (p_status is null or s.status = p_status)
  order by s.created_at desc;
end;
$$;

-- Aplica ou ignora uma sugestao.
--
-- Sugestao NUNCA cria cadastro sozinha: 'novo_gestor' e 'nova_empresa'
-- so ficam sinalizadas, mesmo quando aprovadas. O que se aplica de
-- verdade e troca de campo em cadastro que ja existe - e com rastro em
-- gestores_historico.
create or replace function admin_aplicar_sugestao(
  p_sugestao_id uuid, p_aprovar boolean
)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare
  s record;
  v_quem text := auth.jwt() ->> 'email';
  v_aplicou boolean := false;
begin
  perform exigir_admin();

  select * into s from sugestoes_ia where id = p_sugestao_id for update;
  if s.id is null then raise exception 'Sugestao nao encontrada.'; end if;
  if s.status <> 'pendente' then raise exception 'Sugestao ja revisada.'; end if;

  if not p_aprovar then
    update sugestoes_ia
       set status='ignorada', revisado_por=v_quem, revisado_em=now()
     where id = p_sugestao_id;
    return jsonb_build_object('ok', true, 'aplicada', false);
  end if;

  if s.tipo in ('troca_empresa','dado_divergente')
     and s.gestor_id is not null
     and s.campo is not null then

    perform registrar_hist_gestor(s.gestor_id, s.campo, s.valor_atual,
                                  s.valor_sugerido, coalesce(s.fonte,'ia'));

    -- lista branca de colunas: o campo vem de dado, e format(%I) com
    -- nome arbitrario abriria caminho para escrever onde nao deve
    if s.campo not in ('empresa','cargo','telefone','segmento','estado',
                       'cidade','cnpj','perfil','faturamento','funcionarios') then
      raise exception 'Campo "%" nao pode ser alterado por sugestao.', s.campo;
    end if;

    execute format('update gestores set %I = $1 where id = $2', s.campo)
      using s.valor_sugerido, s.gestor_id;

    v_aplicou := true;
  end if;

  update sugestoes_ia
     set status = case when v_aplicou then 'aplicada' else 'aprovada' end,
         revisado_por = v_quem, revisado_em = now()
   where id = p_sugestao_id;

  return jsonb_build_object('ok', true, 'aplicada', v_aplicou);
end;
$$;

-- =====================================================================
-- 4. ALOCACAO DE QUARTOS  (operacao: staff basta)
-- =====================================================================

-- Uma linha por pessoa; a tela agrupa por reserva. Devolver por pessoa
-- e o que permite buscar "quem esta no 214" sem uma segunda chamada.
create or replace function admin_listar_alocacao(
  p_evento_slug text, p_apenas_sem_quarto boolean default false
)
returns table (
  reserva_id uuid, nome text, empresa text, quarto_tipo text,
  quarto_id uuid, quarto_numero text, origem text
)
language plpgsql stable security definer set search_path = gestao, public as $$
begin
  perform exigir_staff();
  return query
  select r.id, o.nome,
         coalesce(pt.empresa, g.empresa),
         r.tipo, r.quarto_id, q.numero, r.origem
  from reservas r
  join ocupantes o on o.reserva_id = r.id
  left join quartos q         on q.id = r.quarto_id
  left join patrocinadores pt on pt.id = r.patrocinador_id
  left join participantes pa  on pa.id = r.participante_id
  left join gestores g        on g.id = pa.gestor_id
  where r.evento_id = evento_id_por_slug(p_evento_slug)
    and r.status <> 'cancelado'
    and (not p_apenas_sem_quarto or r.quarto_id is null)
  order by coalesce(pt.empresa, g.empresa), r.created_at, o.created_at;
end;
$$;

create or replace function admin_quartos_livres(p_evento_slug text)
returns table (id uuid, numero text, tipo text, capacidade int, bloco text)
language plpgsql stable security definer set search_path = gestao, public as $$
begin
  perform exigir_staff();
  return query
  select q.id, q.numero, q.tipo, q.capacidade, q.bloco
  from quartos q
  where q.evento_id = evento_id_por_slug(p_evento_slug)
    and q.status <> 'bloqueado'
    and not exists (select 1 from reservas r
                    where r.quarto_id = q.id and r.status <> 'cancelado')
  order by q.numero nulls last;
end;
$$;

-- Atribui (ou solta) o quarto fisico de uma reserva.
--
-- Trava o quarto antes de checar: duas pessoas na recepcao mexendo na
-- mesma lista dariam o mesmo apartamento para duas familias. Recusa por
-- capacidade devolve os numeros para a tela poder explicar o motivo.
create or replace function admin_alocar_quarto(
  p_reserva_id uuid, p_quarto_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare
  r record;
  q record;
  v_ocup int;
begin
  perform exigir_staff();

  select * into r from reservas where id = p_reserva_id for update;
  if r.id is null then raise exception 'Reserva nao encontrada.'; end if;

  -- liberar
  if p_quarto_id is null then
    update reservas set quarto_id = null where id = p_reserva_id;
    if r.quarto_id is not null then
      update quartos set status = 'disponivel' where id = r.quarto_id;
    end if;
    return jsonb_build_object('ok', true, 'liberado', true);
  end if;

  select * into q from quartos where id = p_quarto_id for update;
  if q.id is null then raise exception 'Quarto nao encontrado.'; end if;
  if q.evento_id <> r.evento_id then
    raise exception 'Quarto e reserva sao de eventos diferentes.';
  end if;

  if exists (select 1 from reservas r2
             where r2.quarto_id = p_quarto_id
               and r2.id <> p_reserva_id
               and r2.status <> 'cancelado') then
    return jsonb_build_object('ok', false, 'motivo', 'quarto_ocupado');
  end if;

  select count(*) into v_ocup from ocupantes where reserva_id = p_reserva_id;

  if v_ocup > q.capacidade then
    return jsonb_build_object('ok', false, 'motivo', 'capacidade',
                              'ocupantes', v_ocup, 'capacidade', q.capacidade);
  end if;

  -- solta o anterior antes de ocupar o novo
  if r.quarto_id is not null and r.quarto_id <> p_quarto_id then
    update quartos set status = 'disponivel' where id = r.quarto_id;
  end if;

  update reservas set quarto_id = p_quarto_id where id = p_reserva_id;
  update quartos  set status = 'reservado'    where id = p_quarto_id;

  return jsonb_build_object('ok', true, 'quarto', q.numero);
end;
$$;


-- =====================================================================
-- 6. SESSOES, CONVIDADOS E MATCH
-- =====================================================================

create or replace function admin_listar_sessoes(
  p_evento_slug text, p_tipo text default null
)
returns table (
  sessao_id uuid, patrocinador text, patrocinador_id uuid, cota text,
  tipo text, data date, horario time, local text,
  vagas int, escolhidos bigint, encerrada boolean
)
language plpgsql stable security definer set search_path = gestao, public as $$
begin
  perform exigir_staff();
  return query
  select s.id, pt.empresa, pt.id, c.nome, s.tipo, s.data, s.horario, s.local,
         s.vagas,
         (select count(*) from sessao_convidados sc
           where sc.sessao_id = s.id and sc.status = 'confirmado'),
         s.escolha_encerrada_em is not null
  from sessoes s
  join patrocinadores pt on pt.id = s.patrocinador_id
  left join cotas c on c.id = pt.cota_id
  where s.evento_id = evento_id_por_slug(p_evento_slug)
    and (p_tipo is null or s.tipo = p_tipo)
  order by c.ordem_prioridade nulls last, s.data nulls last, pt.empresa;
end;
$$;


create or replace function admin_adicionar_convidado_sessao(
  p_sessao_id uuid, p_participante_id uuid,
  p_aderencia numeric default null, p_rotulo text default null
)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare
  s record;
  v_ocup int;
begin
  perform exigir_admin();

  select * into s from sessoes where id = p_sessao_id for update;
  if s.id is null then raise exception 'Sessao nao encontrada.'; end if;

  -- mesmo convidado nao repete em outra sessao do mesmo tipo (a regra
  -- de "nao repetir na mesma mesa em dias diferentes")
  if exists (select 1 from sessao_convidados sc
             join sessoes s2 on s2.id = sc.sessao_id
             where sc.participante_id = p_participante_id
               and sc.status = 'confirmado'
               and s2.evento_id = s.evento_id
               and s2.tipo = s.tipo) then
    raise exception 'Esse convidado ja esta em outra sessao deste tipo.';
  end if;

  select count(*) into v_ocup from sessao_convidados
  where sessao_id = p_sessao_id and status = 'confirmado';

  if v_ocup >= s.vagas then
    raise exception 'A sessao ja esta com as % vaga(s) preenchidas.', s.vagas;
  end if;

  insert into sessao_convidados (sessao_id, participante_id, origem,
                                 aderencia, rotulo, status)
  values (p_sessao_id, p_participante_id,
          case when p_aderencia is null then 'admin' else 'match' end,
          p_aderencia, p_rotulo, 'confirmado')
  on conflict do nothing;

  return jsonb_build_object('ok', true);
end;
$$;

-- Remover nao apaga: marca 'removido'. A vaga volta, mas fica o rastro
-- de quem passou pela sessao.
create or replace function admin_remover_convidado_sessao(
  p_sessao_id uuid, p_participante_id uuid
)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
begin
  perform exigir_admin();

  update sessao_convidados
     set status = 'removido'
   where sessao_id = p_sessao_id
     and participante_id = p_participante_id
     and status = 'confirmado';

  -- a sessao volta a aceitar escolha se estava encerrada por lotacao
  update sessoes
     set escolha_encerrada_em = null
   where id = p_sessao_id
     and passou_em is null
     and escolha_encerrada_em is not null;

  return jsonb_build_object('ok', true);
end;
$$;


-- =====================================================================
-- 7. PERMISSOES
-- =====================================================================
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'gestao'
      and (p.proname like 'admin%' or p.proname like 'exigir%')
  loop
    execute format('revoke execute on function %s from anon', f.sig);
  end loop;
end $$;
