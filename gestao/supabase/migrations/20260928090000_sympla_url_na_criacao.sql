-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- jantar_salvar: corrige sympla_status ao CRIAR jantar com link do
-- Sympla ja preenchido.
--
-- O formulario "Novo jantar" (jantares.html) ganhou o campo "Link do
-- Sympla" na criacao — antes so existia na tela de detalhe. A funcao
-- ja tratava isso na EDICAO (UPDATE flipa sympla_status de 'pendente'
-- pra 'criado' quando o link vem preenchido), mas o ramo de INSERT
-- nunca fazia o mesmo: gravava sympla_url normalmente e deixava
-- sympla_status no default da coluna ('pendente'), mesmo com o link
-- ja' la'. Resultado: jantar criado com link colado nasceria com o
-- selo "Ainda nao criado" — inconsistente com o proprio dado que
-- acabou de ser salvo.
--
-- So repete no INSERT a mesma regra que ja existe no UPDATE. Nenhuma
-- mudanca de assinatura — CREATE OR REPLACE basta.
-- =====================================================================

set search_path = gestao, public;

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
                          cep, criado_por, sympla_status, sympla_criado_em)
    values (p_data, p_horario, p_local, trim(p_patrocinador_nome),
            p_patrocinador_site, p_perfil_convidado, p_observacoes,
            p_abrangencia, coalesce(p_capacidade,8), p_status,
            nullif(trim(p_sympla_url),''), p_mensagem,
            nullif(regexp_replace(coalesce(p_cep,''), '\D', '', 'g'), ''),
            auth.jwt() ->> 'email',
            case when nullif(trim(p_sympla_url),'') is not null then 'criado' else 'pendente' end,
            case when nullif(trim(p_sympla_url),'') is not null then now() else null end)
    returning id into v_id;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

revoke execute on function jantar_salvar(text,uuid,date,time without time zone,text,text,text,text,text,integer,text,text,text,text) from public, anon;
grant execute on function jantar_salvar(text,uuid,date,time without time zone,text,text,text,text,text,integer,text,text,text,text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Self-check: cria um jantar com link ja preenchido e confere que
-- nasce com sympla_status='criado', nao 'pendente'. jantar_salvar()
-- exige is_admin() (via _exige_admin()) — quem roda a migration nao
-- necessariamente tem isso, entao simula um JWT de service_role so'
-- pra esta transacao (mesmo mecanismo que a migration 20260909210000
-- corrigiu: auth.jwt()->>'role' = 'service_role').
-- ---------------------------------------------------------------------
do $$
declare v_id uuid; v_status text;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);

  v_id := (jantar_salvar(
    p_patrocinador_nome => 'Selftest sympla_url na criacao',
    p_sympla_url => 'https://www.sympla.com.br/selftest__999999'
  )->>'id')::uuid;

  select sympla_status into v_status from jantares where id = v_id;
  if v_status <> 'criado' then
    raise exception 'jantar criado com link deveria nascer sympla_status=criado, veio %', v_status;
  end if;

  delete from jantares where id = v_id;
end $$;
