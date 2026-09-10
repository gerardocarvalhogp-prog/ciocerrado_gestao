-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Bloco 5.4 (resto) — area do CIO: editar os proprios dados e indicar
-- outra pessoa para o evento.
--
-- Editar dados proprios: reaproveita gestores_historico, o mesmo trilho
-- de auditoria que admin_aplicar_sugestao ja usa quando a IA corrige um
-- campo — so muda quem disparou (detectado_por = 'cio' em vez de 'ia').
-- Nao deixa mexer em email/cpf (chave de identidade e documento do
-- contrato) nem em campos que so' admin controla (status, perfil).
--
-- Indicar outra pessoa: cria gestor+participante com origem='indicacao'
-- e status='pendente' — os MESMOS valores que o cadastro por Sympla ou
-- autocadastro ja produzem. Isso significa que a pessoa indicada cai
-- direto na fila de aprovacao que ja existe (aba Aprovacoes, generica
-- por origem — nao precisou de tela nova nenhuma). admin_aprovar_participante
-- ja enfileira o e-mail de aprovacao pela fila de notificacoes existente.
-- Nenhum e-mail sai sozinho: e' o organizador que aprova.
-- =====================================================================

set search_path = gestao, public;

alter table participantes
  add column if not exists indicado_por_participante_id uuid references participantes(id);

-- ---------------------------------------------------------------------
-- editar dados proprios
-- ---------------------------------------------------------------------
create or replace function part_meus_dados(p_evento_slug text)
returns table (
  nome text, telefone text, cargo text, empresa text, segmento text,
  cidade text, estado text, linkedin text
)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_part uuid;
begin
  v_part := _meu_participante(p_evento_slug);
  if v_part is null then
    raise exception 'Inscricao nao encontrada' using errcode = 'P0002';
  end if;

  return query
    select g.nome, g.telefone, g.cargo, g.empresa, g.segmento,
           g.cidade, g.estado, g.linkedin
    from participantes pa join gestores g on g.id = pa.gestor_id
    where pa.id = v_part;
end;
$$;

revoke execute on function part_meus_dados(text) from public, anon;
grant execute on function part_meus_dados(text) to authenticated, service_role;

create or replace function part_salvar_meus_dados(
  p_evento_slug text, p_nome text DEFAULT NULL::text,
  p_telefone text DEFAULT NULL::text, p_cargo text DEFAULT NULL::text,
  p_empresa text DEFAULT NULL::text, p_segmento text DEFAULT NULL::text,
  p_cidade text DEFAULT NULL::text, p_estado text DEFAULT NULL::text,
  p_linkedin text DEFAULT NULL::text
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_part uuid; v_gestor uuid; v_atual gestores%rowtype;
begin
  v_part := _meu_participante(p_evento_slug);
  if v_part is null then
    raise exception 'Inscricao nao encontrada' using errcode = 'P0002';
  end if;

  select gestor_id into v_gestor from participantes where id = v_part;
  select * into v_atual from gestores where id = v_gestor;

  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome' using errcode = '22023';
  end if;

  if v_atual.nome     is distinct from trim(p_nome) then
    insert into gestores_historico (gestor_id, campo, valor_antigo, valor_novo, detectado_por)
    values (v_gestor, 'nome', v_atual.nome, trim(p_nome), 'cio');
  end if;
  if v_atual.telefone  is distinct from p_telefone then
    insert into gestores_historico (gestor_id, campo, valor_antigo, valor_novo, detectado_por)
    values (v_gestor, 'telefone', v_atual.telefone, p_telefone, 'cio');
  end if;
  if v_atual.cargo     is distinct from p_cargo then
    insert into gestores_historico (gestor_id, campo, valor_antigo, valor_novo, detectado_por)
    values (v_gestor, 'cargo', v_atual.cargo, p_cargo, 'cio');
  end if;
  if v_atual.empresa   is distinct from p_empresa then
    insert into gestores_historico (gestor_id, campo, valor_antigo, valor_novo, detectado_por)
    values (v_gestor, 'empresa', v_atual.empresa, p_empresa, 'cio');
  end if;
  if v_atual.segmento  is distinct from p_segmento then
    insert into gestores_historico (gestor_id, campo, valor_antigo, valor_novo, detectado_por)
    values (v_gestor, 'segmento', v_atual.segmento, p_segmento, 'cio');
  end if;

  update gestores set
    nome      = trim(p_nome),
    telefone  = p_telefone,
    cargo     = p_cargo,
    empresa   = p_empresa,
    segmento  = p_segmento,
    cidade    = p_cidade,
    estado    = p_estado,
    linkedin  = p_linkedin,
    updated_at = now()
  where id = v_gestor;

  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function part_salvar_meus_dados(text,text,text,text,text,text,text,text,text) from public, anon;
grant execute on function part_salvar_meus_dados(text,text,text,text,text,text,text,text,text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- indicar outra pessoa
-- ---------------------------------------------------------------------
create or replace function part_indicar_pessoa(
  p_evento_slug text, p_nome text, p_email text,
  p_telefone text DEFAULT NULL::text, p_empresa text DEFAULT NULL::text,
  p_cargo text DEFAULT NULL::text
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_part uuid; v_evento uuid; v_gestor uuid; v_novo_gestor uuid; v_novo_part uuid;
begin
  v_part := _meu_participante(p_evento_slug);
  if v_part is null then
    raise exception 'Inscricao nao encontrada' using errcode = 'P0002';
  end if;

  select evento_id, gestor_id into v_evento, v_gestor
  from participantes where id = v_part;

  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome da pessoa indicada' using errcode = '22023';
  end if;
  if coalesce(trim(p_email),'') = '' then
    raise exception 'Informe o e-mail da pessoa indicada' using errcode = '22023';
  end if;

  select id into v_novo_gestor from gestores where email_norm = norm_doc(p_email);
  if v_novo_gestor is null then
    insert into gestores (nome, email, telefone, empresa, cargo, origem)
    values (trim(p_nome), trim(p_email), p_telefone, p_empresa, p_cargo, 'indicacao')
    returning id into v_novo_gestor;
  end if;

  if exists (
    select 1 from participantes
    where evento_id = v_evento and gestor_id = v_novo_gestor and status <> 'cancelado'
  ) then
    raise exception 'Essa pessoa ja esta inscrita neste evento' using errcode = '23505';
  end if;

  insert into participantes (evento_id, gestor_id, status, origem, indicado_por_participante_id)
  values (v_evento, v_novo_gestor, 'pendente', 'indicacao', v_part)
  returning id into v_novo_part;

  return jsonb_build_object('ok', true, 'id', v_novo_part);
end;
$$;

revoke execute on function part_indicar_pessoa(text,text,text,text,text,text) from public, anon;
grant execute on function part_indicar_pessoa(text,text,text,text,text,text) to authenticated, service_role;

create or replace function part_minhas_indicacoes(p_evento_slug text)
returns table (nome text, email text, empresa text, status text, created_at timestamptz)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_part uuid;
begin
  v_part := _meu_participante(p_evento_slug);
  if v_part is null then
    raise exception 'Inscricao nao encontrada' using errcode = 'P0002';
  end if;

  return query
    select g.nome, g.email, g.empresa, pa.status, pa.created_at
    from participantes pa join gestores g on g.id = pa.gestor_id
    where pa.indicado_por_participante_id = v_part
    order by pa.created_at desc;
end;
$$;

revoke execute on function part_minhas_indicacoes(text) from public, anon;
grant execute on function part_minhas_indicacoes(text) to authenticated, service_role;
