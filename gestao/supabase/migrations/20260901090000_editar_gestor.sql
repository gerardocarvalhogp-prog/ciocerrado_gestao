-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Editar gestor, um de cada vez — faltava.
--
-- A base de gestores so tinha dois caminhos de escrita: importar
-- planilha (em lote, "celula vazia nao apaga") e vincular a uma
-- empresa (um prompt() nativo, so isso). Corrigir um nome errado, ou
-- completar segmento/cidade/UF de uma pessoa so, nao tinha onde
-- acontecer — precisava editar a planilha inteira e reimportar.
--
-- Diferente do importador, aqui e edicao de verdade: o campo que for
-- limpo no formulario grava NULL, nao fica preservando o que ja
-- existia (isso e o comportamento certo pra "editar", errado pra
-- "importar em lote" — os dois nao podem usar a mesma regra).
-- =====================================================================

set search_path = gestao, public;

-- So os campos que a tela realmente mostra e edita. Um parametro pra
-- campo que o formulario nao exibe (ex.: cnpj) e risco de apagar dado
-- que a pessoa nem viu, sem querer — se um dia a tela ganhar esse
-- campo, ele entra aqui junto, nao antes.
create or replace function admin_editar_gestor(
  p_id       uuid,
  p_nome     text,
  p_email    text default null,
  p_cargo    text default null,
  p_telefone text default null,
  p_empresa  text default null,
  p_segmento text default null,
  p_cidade   text default null,
  p_estado   text default null,
  p_perfil   text default null,
  p_linkedin text default null
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_admin();

  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome' using errcode = '22023';
  end if;

  update gestores set
    nome     = trim(p_nome),
    email    = nullif(trim(p_email),''),
    cargo    = nullif(trim(p_cargo),''),
    telefone = nullif(trim(p_telefone),''),
    empresa  = nullif(trim(p_empresa),''),
    segmento = nullif(trim(p_segmento),''),
    cidade   = nullif(trim(p_cidade),''),
    estado   = nullif(trim(p_estado),''),
    perfil   = nullif(trim(p_perfil),''),
    linkedin = nullif(trim(p_linkedin),'')
  where id = p_id;

  if not found then
    raise exception 'Gestor nao encontrado' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function admin_editar_gestor(uuid,text,text,text,text,text,text,text,text,text,text) from public, anon;
grant execute on function admin_editar_gestor(uuid,text,text,text,text,text,text,text,text,text,text) to authenticated, service_role;
