-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Redesign do "Gerar sessões": cotas que não escolhem convidado entram
-- em sorteio, escolhido com o Gerardo entre as opções levantadas —
-- "cotas baixas, por regra": certas cotas nunca têm janela de escolha
-- própria, são sempre preenchidas por sorteio direto.
--
-- O PERIGO QUE ISSO TRAZIA ESCONDIDO
--
-- v_ordem_escolha, que comanda a fila de quem escolhe primeiro, listava
-- TODO patrocinador ativo. Uma cota marcada "não escolhe" nunca chama
-- patro_escolher_convidados nem patro_passar_a_vez — a sessão dela
-- nunca fecha (_escolha_em_aberto fica true pra sempre), e toda cota
-- de prioridade mais baixa que ela ficaria esperando a vez de uma
-- empresa que nunca vai escolher. v_ordem_escolha agora exclui essas
-- cotas — elas nem entram na fila, o sorteio é independente dela.
-- =====================================================================

set search_path = gestao, public;

alter table cotas add column if not exists escolhe_convidados boolean not null default true;
comment on column cotas.escolhe_convidados is
  'false = cota nunca tem janela de escolha propria; as vagas dela sao preenchidas por sorteio (admin_sortear_sessao), fora da fila.';

-- ---------------------------------------------------------------------
-- 1. FILA IGNORA QUEM NAO ESCOLHE (o conserto do perigo acima)
-- ---------------------------------------------------------------------
create or replace view v_ordem_escolha as
  select p.evento_id, p.id as patrocinador_id, p.empresa, c.nome as cota,
         c.ordem_prioridade, p.fechado_em,
         row_number() over (partition by p.evento_id
                             order by c.ordem_prioridade, p.fechado_em, p.created_at) as posicao
  from patrocinadores p
  join cotas c on c.id = p.cota_id
  where p.status = 'ativo' and c.escolhe_convidados;

alter view v_ordem_escolha set (security_invoker = true);

-- ---------------------------------------------------------------------
-- 2. CADASTRO DA COTA GANHA O CAMPO
-- ---------------------------------------------------------------------
drop function if exists admin_salvar_cota(text,text,integer,jsonb,integer,boolean,boolean,date,integer,integer);

create or replace function admin_salvar_cota(
  p_evento_slug text, p_nome text, p_ordem integer,
  p_quartos jsonb DEFAULT '{}'::jsonb, p_vagas_mesa integer DEFAULT 0,
  p_reuniao boolean DEFAULT false, p_jantar boolean DEFAULT false,
  p_prazo_indicacao date DEFAULT NULL::date, p_janela_horas integer DEFAULT NULL::integer,
  p_limite_indicacoes integer DEFAULT NULL::integer,
  p_escolhe_convidados boolean DEFAULT true
) returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
declare
  v_evento uuid; v_unica boolean; v_conflito text;
  v_cota uuid; v_par record; v_ordem int; v_total int := 0;
begin
  perform _exige_admin();

  select id, cota_unica into v_evento, v_unica
  from eventos where slug = p_evento_slug;

  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;
  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome da cota' using errcode='22023';
  end if;
  if p_janela_horas is not null and p_janela_horas <= 0 then
    raise exception 'A janela em horas comeca em 1' using errcode='22023';
  end if;
  if p_limite_indicacoes is not null and p_limite_indicacoes < 0 then
    raise exception 'O limite de indicacoes nao pode ser negativo' using errcode='22023';
  end if;

  v_ordem := case when v_unica then 1 else p_ordem end;

  if v_ordem is null or v_ordem < 1 then
    raise exception 'A ordem de prioridade comeca em 1' using errcode='22023';
  end if;

  if not v_unica then
    select c.nome into v_conflito from cotas c
     where c.evento_id = v_evento and c.ordem_prioridade = v_ordem
       and lower(c.nome) <> lower(trim(p_nome));
    if v_conflito is not null then
      raise exception 'A posicao % ja e da cota "%"', v_ordem, v_conflito
        using errcode='23505';
    end if;
  end if;

  insert into cotas (evento_id, nome, ordem_prioridade, vagas_mesa_redonda,
                     tem_reuniao_exclusiva, tem_jantar,
                     quartos_incluidos, tipo_quarto_padrao, prazo_indicacao,
                     janela_horas, limite_indicacoes, escolhe_convidados)
  values (v_evento, trim(p_nome), v_ordem, coalesce(p_vagas_mesa,0),
          p_reuniao, p_jantar, 0, 'duplo', p_prazo_indicacao, p_janela_horas,
          p_limite_indicacoes, coalesce(p_escolhe_convidados, true))
  on conflict (evento_id, nome) do update set
    ordem_prioridade = excluded.ordem_prioridade,
    vagas_mesa_redonda = excluded.vagas_mesa_redonda,
    tem_reuniao_exclusiva = excluded.tem_reuniao_exclusiva,
    tem_jantar = excluded.tem_jantar,
    prazo_indicacao = excluded.prazo_indicacao,
    janela_horas = excluded.janela_horas,
    limite_indicacoes = excluded.limite_indicacoes,
    escolhe_convidados = excluded.escolhe_convidados
  returning id into v_cota;

  delete from cota_quartos where cota_id = v_cota;

  for v_par in
    select key as tipo, (value #>> '{}')::int as qtd
    from jsonb_each(coalesce(p_quartos, '{}'::jsonb))
  loop
    if v_par.tipo not in ('single','duplo','triplo') then
      raise exception 'Tipo de quarto invalido: %', v_par.tipo using errcode='22023';
    end if;
    if coalesce(v_par.qtd,0) > 0 then
      insert into cota_quartos (cota_id, tipo, quantidade)
      values (v_cota, v_par.tipo, v_par.qtd);
      v_total := v_total + v_par.qtd;
    end if;
  end loop;

  update cotas set quartos_incluidos = v_total where id = v_cota;

  return jsonb_build_object('ok', true, 'id', v_cota, 'total_quartos', v_total);
end;
$$;

drop function if exists admin_listar_cotas(text);

create or replace function admin_listar_cotas(p_evento_slug text)
returns table (
  id uuid, nome text, ordem_prioridade integer, quartos jsonb,
  total_quartos bigint, vagas_mesa_redonda integer,
  tem_reuniao_exclusiva boolean, tem_jantar boolean,
  patrocinadores bigint, lista_patrocinadores jsonb,
  prazo_indicacao date, janela_horas integer, limite_indicacoes integer,
  escolhe_convidados boolean
)
language plpgsql stable security definer
set search_path to 'gestao', 'public' as $$
begin
  perform _exige_staff();
  return query
    select c.id, c.nome, c.ordem_prioridade,
           coalesce((select jsonb_object_agg(cq.tipo, cq.quantidade)
                     from cota_quartos cq where cq.cota_id = c.id
                       and cq.quantidade > 0), '{}'::jsonb),
           coalesce((select sum(cq.quantidade) from cota_quartos cq
                     where cq.cota_id = c.id), 0),
           c.vagas_mesa_redonda, c.tem_reuniao_exclusiva, c.tem_jantar,
           (select count(*) from patrocinadores p where p.cota_id = c.id),
           coalesce((select jsonb_agg(jsonb_build_object(
                       'id', p.id, 'empresa', p.empresa) order by p.empresa)
                     from patrocinadores p
                     where p.cota_id = c.id and p.status = 'ativo'), '[]'::jsonb),
           c.prazo_indicacao, c.janela_horas, c.limite_indicacoes, c.escolhe_convidados
    from cotas c
    join eventos e on e.id = c.evento_id and e.slug = p_evento_slug
    order by c.ordem_prioridade;
end;
$$;

revoke execute on function admin_salvar_cota(text,text,integer,jsonb,integer,boolean,boolean,date,integer,integer,boolean) from public, anon;
revoke execute on function admin_listar_cotas(text) from public, anon;
grant execute on function admin_salvar_cota(text,text,integer,jsonb,integer,boolean,boolean,date,integer,integer,boolean) to authenticated, service_role;
grant execute on function admin_listar_cotas(text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3. PORTAL SABE QUE NAO E PRA MOSTRAR A TELA DE ESCOLHA
-- ---------------------------------------------------------------------
drop function if exists patro_minhas_sessoes(uuid);

create or replace function patro_minhas_sessoes(p_patrocinador_id uuid)
returns table(sessao_id uuid, tipo text, data date, horario time, local text,
              vagas integer, escolhidos bigint, encerrada boolean, passou boolean,
              escolhe_convidados boolean)
language plpgsql stable security definer
set search_path to 'gestao', 'public' as $$
begin
  perform _exige_patrocinador(p_patrocinador_id);
  return query
    select s.id, s.tipo, s.data, s.horario, s.local, s.vagas,
           (select count(*) from sessao_convidados sc
             where sc.sessao_id = s.id and sc.status = 'confirmado'),
           (s.escolha_encerrada_em is not null or s.passou_em is not null),
           (s.passou_em is not null),
           coalesce(c.escolhe_convidados, true)
    from sessoes s
    join patrocinadores p on p.id = s.patrocinador_id
    left join cotas c on c.id = p.cota_id
    where s.patrocinador_id = p_patrocinador_id
    order by s.tipo, s.data, s.horario;
end;
$$;

revoke execute on function patro_minhas_sessoes(uuid) from public, anon;
grant execute on function patro_minhas_sessoes(uuid) to authenticated, service_role;

-- guarda de verdade: mesmo que a tela nunca mostre o formulario pra
-- essas cotas, quem chamar a RPC direto tambem esbarra na regra
create or replace function patro_escolher_convidados(p_sessao_id uuid, p_participantes uuid[])
returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
declare
  v_patro uuid; v_vagas int; v_tipo text; v_evento uuid;
  v_atual int; v_vez jsonb; v_inseridos int := 0; v_p uuid;
  v_dono uuid; v_empresa text; v_passou timestamptz; v_encerrada timestamptz;
  v_escolhe boolean;
begin
  select s.patrocinador_id, s.vagas, s.tipo, s.evento_id,
         s.passou_em, s.escolha_encerrada_em
    into v_patro, v_vagas, v_tipo, v_evento, v_passou, v_encerrada
  from sessoes s where s.id = p_sessao_id
  for update;

  perform _exige_patrocinador(v_patro);

  select c.escolhe_convidados into v_escolhe
  from patrocinadores p join cotas c on c.id = p.cota_id
  where p.id = v_patro;

  if coalesce(v_escolhe, true) is false then
    raise exception 'Sua cota nao escolhe os proprios convidados — a organizacao preenche por sorteio'
      using errcode = '55000';
  end if;

  v_vez := patro_minha_vez(p_sessao_id);

  if v_passou is not null then
    raise exception 'Voce passou a vez nesta sessao. As vagas foram liberadas para as proximas empresas.'
      using errcode = '55000';
  end if;

  if v_encerrada is not null then
    raise exception 'A escolha desta sessao ja foi encerrada.'
      using errcode = '55000';
  end if;

  if (v_vez ->> 'prazo_vencido')::boolean then
    raise exception 'O prazo da sua cota terminou em %. A escolha passou para as proximas cotas.',
      to_char((v_vez ->> 'janela_fim')::timestamptz, 'DD/MM/YYYY HH24:MI')
      using errcode = '55000';
  end if;

  if not (v_vez ->> 'minha_vez')::boolean then
    raise exception 'Ainda nao e a sua vez de escolher (% na frente)',
      v_vez ->> 'na_frente' using errcode = '55000';
  end if;

  select count(*) into v_atual from sessao_convidados
   where sessao_id = p_sessao_id and status = 'confirmado';

  if v_atual + array_length(p_participantes,1) > v_vagas then
    raise exception 'Cota de % vaga(s); voce ja tem % e tentou somar %',
      v_vagas, v_atual, array_length(p_participantes,1)
      using errcode = '22023';
  end if;

  foreach v_p in array p_participantes loop
    if exists (
      select 1 from sessao_convidados sc
      join sessoes s3 on s3.id = sc.sessao_id
      where sc.participante_id = v_p and sc.status = 'confirmado'
        and s3.evento_id = v_evento and s3.tipo = v_tipo
    ) then
      raise exception 'Convidado ja esta em outra sessao deste tipo'
        using errcode = '23505';
    end if;

    v_dono := _reserva_da_indicacao(v_p, v_tipo);
    if v_dono is not null and v_dono <> v_patro then
      select empresa into v_empresa from patrocinadores where id = v_dono;
      raise exception 'Convidado indicado pela %, que ainda esta no prazo', v_empresa
        using errcode = '55000';
    end if;

    insert into sessao_convidados (sessao_id, participante_id, origem)
    values (p_sessao_id, v_p, 'patrocinador');
    v_inseridos := v_inseridos + 1;
  end loop;

  if v_atual + v_inseridos >= v_vagas then
    update sessoes set escolha_encerrada_em = now() where id = p_sessao_id;
  end if;

  return jsonb_build_object('ok', true, 'inseridos', v_inseridos,
                            'total', v_atual + v_inseridos, 'vagas', v_vagas);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. O SORTEIO EM SI
-- ---------------------------------------------------------------------
alter table sessao_convidados drop constraint if exists sessao_convidados_origem_check;
alter table sessao_convidados add constraint sessao_convidados_origem_check
  check (origem in ('patrocinador','admin','match','sorteio'));

create or replace function admin_sortear_sessao(p_sessao_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_tipo text; v_vagas int; v_patro uuid; v_escolhe boolean;
  v_atual int; v_restantes int; v_sorteados int := 0; v_p uuid;
begin
  perform _exige_admin();

  select s.evento_id, s.tipo, s.vagas, s.patrocinador_id
    into v_evento, v_tipo, v_vagas, v_patro
  from sessoes s where s.id = p_sessao_id
  for update;

  if v_evento is null then
    raise exception 'Sessao nao encontrada' using errcode = 'P0002';
  end if;

  select c.escolhe_convidados into v_escolhe
  from patrocinadores p join cotas c on c.id = p.cota_id
  where p.id = v_patro;

  if coalesce(v_escolhe, true) then
    raise exception 'Essa cota escolhe os proprios convidados — sorteio nao se aplica'
      using errcode = '55000';
  end if;

  select count(*) into v_atual from sessao_convidados
   where sessao_id = p_sessao_id and status = 'confirmado';
  v_restantes := v_vagas - v_atual;

  if v_restantes <= 0 then
    return jsonb_build_object('ok', true, 'sorteados', 0);
  end if;

  -- mesma exclusao de patro_convidados_disponiveis: ja aprovado, ainda
  -- nao confirmado em nenhuma sessao deste tipo neste evento
  for v_p in
    select pa.id from participantes pa
    where pa.evento_id = v_evento
      and pa.status = 'aprovado'
      and not exists (
        select 1 from sessao_convidados sc
        join sessoes s3 on s3.id = sc.sessao_id
        where sc.participante_id = pa.id
          and sc.status = 'confirmado'
          and s3.evento_id = v_evento
          and s3.tipo = v_tipo)
    order by random()
    limit v_restantes
  loop
    insert into sessao_convidados (sessao_id, participante_id, origem)
    values (p_sessao_id, v_p, 'sorteio');
    v_sorteados := v_sorteados + 1;
  end loop;

  if v_atual + v_sorteados >= v_vagas then
    update sessoes set escolha_encerrada_em = now() where id = p_sessao_id;
  end if;

  return jsonb_build_object('ok', true, 'sorteados', v_sorteados);
end;
$$;

revoke execute on function patro_escolher_convidados(uuid,uuid[]) from public, anon;
revoke execute on function admin_sortear_sessao(uuid) from public, anon;
grant execute on function patro_escolher_convidados(uuid,uuid[]) to authenticated, service_role;
grant execute on function admin_sortear_sessao(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 5. ADMIN VE QUAL COTA E DE SORTEIO NA LISTA DE SESSOES
-- ---------------------------------------------------------------------
drop function if exists admin_listar_sessoes(text, text);

create or replace function admin_listar_sessoes(p_evento_slug text, p_tipo text DEFAULT NULL::text)
returns table(sessao_id uuid, patrocinador text, cota text, tipo text, data date,
              horario time, local text, vagas integer, escolhidos bigint,
              encerrada boolean, escolhe_convidados boolean)
language plpgsql stable security definer
set search_path to 'gestao', 'public' as $$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select s.id, p.empresa, c.nome, s.tipo, s.data, s.horario, s.local,
           s.vagas,
           (select count(*) from sessao_convidados sc
             where sc.sessao_id = s.id and sc.status = 'confirmado'),
           (s.escolha_encerrada_em is not null or s.passou_em is not null),
           coalesce(c.escolhe_convidados, true)
    from sessoes s
    join patrocinadores p on p.id = s.patrocinador_id
    left join cotas c on c.id = p.cota_id
    join eventos e on e.id = s.evento_id and e.slug = p_evento_slug
    where p_tipo is null or s.tipo = p_tipo
    order by c.ordem_prioridade nulls last, p.empresa, s.data;
end;
$$;

revoke execute on function admin_listar_sessoes(text,text) from public, anon;
grant execute on function admin_listar_sessoes(text,text) to authenticated, service_role;
