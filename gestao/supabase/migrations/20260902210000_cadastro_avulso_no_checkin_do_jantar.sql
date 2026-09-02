-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Check-in de jantar ganha "cadastrar quem nao esta na lista", nos
-- mesmos moldes do checkin_cadastrar do evento geral. Ate aqui
-- checkin.html so avisava "quem nao esta na lista se adiciona pela
-- tela de jantares" — sem botao nenhum. Achado real, reportado pelo
-- Gerardo.
--
-- Distincao pedida: se a pessoa e um CIO, ela entra na base geral de
-- gestores com perfil CIO (fica disponivel pra outros eventos, igual
-- o fluxo de checkin_cadastrar). Se nao e CIO (ex.: convidado do
-- proprio patrocinador), fica so registrada pra completar a lista
-- deste jantar — perfil CONVIDADO, pra nao poluir a base de CIOs.
--
-- jantar nao tem evento_id (design deliberado, ver 20260825160000) —
-- entao "entrar na base" aqui e so a tabela gestores, sem criar
-- participante de evento nenhum.
-- =====================================================================

set search_path = gestao, public;

create or replace function jantar_checkin_cadastrar(
  p_jantar_id uuid, p_nome text, p_empresa text DEFAULT NULL::text,
  p_email text DEFAULT NULL::text, p_telefone text DEFAULT NULL::text,
  p_cargo text DEFAULT NULL::text, p_e_cio boolean DEFAULT false
) returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
declare
  v_gestor uuid; v_convidado uuid; v_reaproveitado boolean := false;
begin
  perform _exige_staff();

  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome' using errcode='22023';
  end if;

  if not exists (select 1 from jantares where id = p_jantar_id) then
    raise exception 'Jantar nao encontrado' using errcode='P0002';
  end if;

  if coalesce(trim(p_email),'') <> '' then
    select g.id into v_gestor from gestores g
     where g.email_norm = norm_doc(p_email);
    v_reaproveitado := v_gestor is not null;
  end if;

  if v_gestor is null then
    insert into gestores (nome, email, empresa, cargo, telefone, perfil, origem)
    values (trim(p_nome),
            coalesce(nullif(lower(trim(p_email)),''),
                     'avulso.' || replace(gen_random_uuid()::text,'-','')
                     || '@interno.ciocerrado.com.br'),
            p_empresa, p_cargo, p_telefone,
            case when p_e_cio then 'CIO' else 'CONVIDADO' end, 'manual')
    returning id into v_gestor;
  else
    update gestores set
      empresa  = coalesce(empresa, p_empresa),
      telefone = coalesce(telefone, p_telefone),
      cargo    = coalesce(cargo, p_cargo)
    where id = v_gestor;
  end if;

  insert into jantar_convidados (jantar_id, gestor_id, empresa, origem, status)
  values (p_jantar_id, v_gestor, p_empresa, 'avulso', 'compareceu')
  on conflict (jantar_id, gestor_id) do update set status = 'compareceu'
  returning id into v_convidado;

  return jsonb_build_object('ok', true, 'nome', trim(p_nome),
                            'convidado_id', v_convidado,
                            'gestor_reaproveitado', v_reaproveitado);
end;
$$;

revoke execute on function jantar_checkin_cadastrar(uuid,text,text,text,text,text,boolean) from public, anon;
grant execute on function jantar_checkin_cadastrar(uuid,text,text,text,text,text,boolean) to authenticated, service_role;
