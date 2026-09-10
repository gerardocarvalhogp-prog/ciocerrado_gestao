-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Bloco do RPA do Sympla: falta um campo de CEP em jantares. O
-- formulario de criacao de evento do Sympla pede CEP pra geolocalizar
-- o local (apareceu duas vezes na gravacao real usada pra calibrar o
-- robo) — jantares so' guardava `local` como texto livre ("Salao
-- Alexania"), sem CEP nenhum. Sem isso o robo mandaria o campo em
-- branco e provavelmente travaria no formulario.
-- =====================================================================

set search_path = gestao, public;

alter table jantares add column if not exists cep text;

-- ---------------------------------------------------------------------
-- jantar_salvar ganha p_cep
-- ---------------------------------------------------------------------
drop function if exists jantar_salvar(
  text,uuid,date,time without time zone,text,text,text,text,text,integer,text,text,text);

create or replace function jantar_salvar(
  p_patrocinador_nome text,
  p_id uuid DEFAULT NULL::uuid,
  p_data date DEFAULT NULL::date,
  p_horario time without time zone DEFAULT NULL::time without time zone,
  p_local text DEFAULT NULL::text,
  p_patrocinador_site text DEFAULT NULL::text,
  p_perfil_convidado text DEFAULT NULL::text,
  p_observacoes text DEFAULT NULL::text,
  p_abrangencia text DEFAULT NULL::text,
  p_capacidade integer DEFAULT 8,
  p_status text DEFAULT 'planejado'::text,
  p_sympla_url text DEFAULT NULL::text,
  p_mensagem text DEFAULT NULL::text,
  p_cep text DEFAULT NULL::text
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_id uuid; v_ja int;
begin
  perform _exige_admin();

  if coalesce(trim(p_patrocinador_nome),'') = '' then
    raise exception 'Informe o patrocinador' using errcode='22023';
  end if;
  if p_status not in ('planejado','confirmado','realizado','cancelado') then
    raise exception 'Status invalido: %', p_status using errcode='22023';
  end if;

  if p_id is not null then
    select count(*) into v_ja from jantar_convidados
     where jantar_id = p_id and status in ('confirmado','compareceu');
    if coalesce(p_capacidade,8) < v_ja then
      raise exception 'Já há % confirmado(s); a capacidade não pode ser menor que isso', v_ja
        using errcode='22023';
    end if;

    update jantares set
      data = p_data, horario = p_horario, local = p_local,
      patrocinador_nome = trim(p_patrocinador_nome),
      patrocinador_site = p_patrocinador_site,
      perfil_convidado = p_perfil_convidado,
      observacoes = p_observacoes, abrangencia = p_abrangencia,
      capacidade = coalesce(p_capacidade,8), status = p_status,
      sympla_url = nullif(trim(p_sympla_url),''),
      mensagem = p_mensagem,
      cep = nullif(regexp_replace(coalesce(p_cep,''), '\D', '', 'g'), ''),
      sympla_status = case
        when nullif(trim(p_sympla_url),'') is not null and sympla_status = 'pendente'
          then 'criado' else sympla_status end,
      sympla_criado_em = case
        when nullif(trim(p_sympla_url),'') is not null and sympla_status = 'pendente'
          then now() else sympla_criado_em end
    where id = p_id
    returning id into v_id;
  else
    insert into jantares (data, horario, local, patrocinador_nome,
                          patrocinador_site, perfil_convidado, observacoes,
                          abrangencia, capacidade, status, sympla_url, mensagem,
                          cep, criado_por)
    values (p_data, p_horario, p_local, trim(p_patrocinador_nome),
            p_patrocinador_site, p_perfil_convidado, p_observacoes,
            p_abrangencia, coalesce(p_capacidade,8), p_status,
            nullif(trim(p_sympla_url),''), p_mensagem,
            nullif(regexp_replace(coalesce(p_cep,''), '\D', '', 'g'), ''),
            auth.jwt() ->> 'email')
    returning id into v_id;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

revoke execute on function jantar_salvar(text,uuid,date,time without time zone,text,text,text,text,text,integer,text,text,text,text) from public, anon;
grant execute on function jantar_salvar(text,uuid,date,time without time zone,text,text,text,text,text,integer,text,text,text,text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- jantar_obter e jantar_listar_para_sympla devolvem o cep tambem
-- ---------------------------------------------------------------------
drop function if exists jantar_obter(uuid);

create function jantar_obter(p_id uuid) returns table(
  id uuid, data date, horario time without time zone, local text,
  patrocinador_nome text, patrocinador_site text, perfil_convidado text,
  observacoes text, abrangencia text, capacidade integer, status text,
  sympla_url text, mensagem text, logo_storage_path text,
  sympla_status text, sympla_criado_em timestamptz, cep text
) language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select j.id, j.data, j.horario, j.local, j.patrocinador_nome,
           j.patrocinador_site, j.perfil_convidado, j.observacoes,
           j.abrangencia, j.capacidade, j.status, j.sympla_url,
           j.mensagem, j.logo_storage_path, j.sympla_status, j.sympla_criado_em,
           j.cep
    from jantares j where j.id = p_id;
end;
$$;

revoke execute on function jantar_obter(uuid) from public, anon;
grant execute on function jantar_obter(uuid) to authenticated, service_role;

drop function if exists jantar_listar_para_sympla();

create or replace function jantar_listar_para_sympla()
returns table (
  id uuid, patrocinador_nome text, data date, horario time without time zone,
  local text, capacidade integer, mensagem text, logo_storage_path text,
  sympla_status text, sympla_url text, cep text
) language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();

  return query
    select j.id, j.patrocinador_nome, j.data, j.horario, j.local,
           j.capacidade, j.mensagem, j.logo_storage_path, j.sympla_status, j.sympla_url,
           j.cep
    from jantares j
    where j.status in ('planejado','confirmado')
      and (
        (j.sympla_status = 'pendente' and j.logo_storage_path is not null
           and j.mensagem is not null and j.data is not null)
        or j.sympla_status = 'criado'
      )
    order by j.data nulls last;
end;
$$;

revoke execute on function jantar_listar_para_sympla() from public, anon;
grant execute on function jantar_listar_para_sympla() to authenticated, service_role;
