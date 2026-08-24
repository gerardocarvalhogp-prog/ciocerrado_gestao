-- =====================================================================
-- CIO Cerrado Experience 2026 - Consentimento IBM (Data Privacy + Notice & Choice)
-- Com verificacao em duas etapas: e-mail corporativo + CPF ou data de nascimento.
-- Banco: Supabase / Postgres (mesmo projeto do agendamento de massagem).
-- Rode este arquivo inteiro no SQL Editor do Supabase.
--
-- IMPORTANTE: o CPF e a data de nascimento NAO sao gravados. O banco guarda
-- apenas o hash SHA-256 (com pepper). Se voce alterar o PEPPER abaixo, os
-- hashes do seed param de bater e o seed precisa ser gerado de novo.
-- =====================================================================

create extension if not exists pgcrypto;

create or replace function public.ibm_pepper() returns text
language sql immutable as $$ select 'cio-cerrado-2026::ibm-consent::v1' $$;

-- Versao do texto apresentado ao participante (prova de conformidade).
create table if not exists public.ibm_consent_texto (
  versao    text primary key,
  texto_dp  text not null,
  texto_nc  text not null,
  criado_em timestamptz not null default now()
);

insert into public.ibm_consent_texto (versao, texto_dp, texto_nc) values (
 'v1-2026-08',
 'Ao interagir com a IBM, voce autoriza que a CIO Cerrado ou seu fornecedor forneca suas informacoes de contato a IBM, para que a IBM possa dar continuidade a sua interacao. O uso das suas informacoes de contato pela IBM e regido pela Declaracao de Privacidade da IBM.',
 'Gostaria que meus dados de contato fossem compartilhados com a IBM para que ela possa me manter informado(a) sobre produtos, servicos e ofertas. Mais informacoes sobre como a IBM utiliza dados e as formas de cancelar o recebimento dessas comunicacoes podem ser encontradas na Declaracao de Privacidade da IBM. Caso seja um residente da California nos Estados Unidos, deve consultar a Declaracao de Privacidade Suplementar da California.'
) on conflict (versao) do nothing;

-- ---------------------------------------------------------------------
-- Base de participantes + resposta.
-- ---------------------------------------------------------------------
create table if not exists public.ibm_consent (
  id              bigserial primary key,
  email           text not null unique,
  email_inscricao text,
  nome            text not null,
  sobrenome       text,
  empresa         text,
  cargo           text,
  industria       text,
  pais            text not null default 'Brazil',
  telefone        text,
  hash_cpf        text,          -- sha256(pepper|cpf sem pontuacao)
  hash_nasc       text,          -- sha256(pepper|ddmmaaaa)
  tentativas      int not null default 0,
  bloqueado_ate   timestamptz,
  status          text not null default 'pendente'
                  check (status in ('pendente','aceito','recusado')),
  optin_email     boolean not null default false,
  optin_telefone  boolean not null default false,
  dp_exibido      boolean not null default false,
  texto_versao    text references public.ibm_consent_texto(versao),
  respondido_em   timestamptz,
  atualizado_em   timestamptz,
  user_agent      text,
  origem          text default 'form-web'
);
create index if not exists ibm_consent_status_idx on public.ibm_consent (status);

-- Colunas novas em bases ja criadas pela versao anterior deste script:
alter table public.ibm_consent add column if not exists hash_cpf text;
alter table public.ibm_consent add column if not exists hash_nasc text;
alter table public.ibm_consent add column if not exists tentativas int not null default 0;
alter table public.ibm_consent add column if not exists bloqueado_ate timestamptz;

-- Trilha de auditoria: guarda toda resposta, inclusive mudancas de opiniao.
create table if not exists public.ibm_consent_log (
  id             bigserial primary key,
  email          text not null,
  status         text not null,
  optin_email    boolean not null,
  optin_telefone boolean not null,
  texto_versao   text,
  user_agent     text,
  criado_em      timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- RLS: ninguem le a tabela direto. O site publico so fala pelas funcoes.
-- AJUSTE A LISTA DE ADMINS NOS DOIS BLOCOS ABAIXO.
-- ---------------------------------------------------------------------
alter table public.ibm_consent       enable row level security;
alter table public.ibm_consent_log   enable row level security;
alter table public.ibm_consent_texto enable row level security;

drop policy if exists ibm_consent_admin_read on public.ibm_consent;
create policy ibm_consent_admin_read on public.ibm_consent
  for select to authenticated
  using (auth.jwt() ->> 'email' in (
    'kelson.duarte@ciocerrado.com.br',
    'tacio.henrique@ciocerrado.com.br',
    'comunicacao@ciocerrado.com.br'
  ));

drop policy if exists ibm_consent_log_admin_read on public.ibm_consent_log;
create policy ibm_consent_log_admin_read on public.ibm_consent_log
  for select to authenticated
  using (auth.jwt() ->> 'email' in (
    'kelson.duarte@ciocerrado.com.br',
    'tacio.henrique@ciocerrado.com.br',
    'comunicacao@ciocerrado.com.br'
  ));

drop policy if exists ibm_texto_read on public.ibm_consent_texto;
create policy ibm_texto_read on public.ibm_consent_texto
  for select to anon, authenticated using (true);

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
create or replace function public.ibm_normaliza_email(p_email text)
returns text language sql immutable as $$
  select lower(regexp_replace(coalesce(p_email,''), '\s', '', 'g'));
$$;

create or replace function public.ibm_hash(p_valor text)
returns text language sql stable as $$
  select encode(digest(public.ibm_pepper() || '|' || regexp_replace(coalesce(p_valor,''),'\D','','g'), 'sha256'), 'hex');
$$;

-- Confere e-mail + chave (CPF ou ddmmaaaa). Nao revela se o e-mail existe.
-- Bloqueia por 15 minutos apos 5 tentativas erradas.
create or replace function public.ibm_valida(p_email text, p_chave text)
returns public.ibm_consent
language plpgsql security definer set search_path = public as $$
declare
  v_email text := public.ibm_normaliza_email(p_email);
  v_hash  text := public.ibm_hash(p_chave);
  r public.ibm_consent;
begin
  select * into r from public.ibm_consent where email = v_email for update;
  if not found then return null; end if;
  if r.bloqueado_ate is not null and r.bloqueado_ate > now() then
    raise exception 'BLOQUEADO';
  end if;
  if (r.hash_cpf is not null and r.hash_cpf = v_hash)
     or (r.hash_nasc is not null and r.hash_nasc = v_hash) then
    update public.ibm_consent set tentativas = 0, bloqueado_ate = null where id = r.id;
    return r;
  end if;
  update public.ibm_consent
     set tentativas = r.tentativas + 1,
         bloqueado_ate = case when r.tentativas + 1 >= 5 then now() + interval '15 minutes' else null end
   where id = r.id;
  return null;
end; $$;

-- 1) Identificacao. Devolve os dados de cadastro para conferencia.
create or replace function public.ibm_autenticar(p_email text, p_chave text)
returns table (
  ok boolean, motivo text, nome text, sobrenome text, empresa text, cargo text,
  email text, telefone text, status text, optin_email boolean, optin_telefone boolean,
  respondido_em timestamptz
)
language plpgsql security definer set search_path = public as $$
declare r public.ibm_consent;
begin
  begin
    r := public.ibm_valida(p_email, p_chave);
  exception when others then
    if sqlerrm = 'BLOQUEADO' then
      return query select false, 'bloqueado'::text, null::text, null::text, null::text, null::text,
                          null::text, null::text, null::text, null::boolean, null::boolean, null::timestamptz;
      return;
    end if;
    raise;
  end;
  if r.id is null then
    return query select false, 'nao_confere'::text, null::text, null::text, null::text, null::text,
                        null::text, null::text, null::text, null::boolean, null::boolean, null::timestamptz;
    return;
  end if;
  return query select true, 'ok'::text, r.nome, r.sobrenome, r.empresa, r.cargo,
                      r.email, r.telefone, r.status, r.optin_email, r.optin_telefone, r.respondido_em;
end; $$;

-- 2) Registro da resposta. Revalida a chave. Sem marcar nada = 'recusado'.
create or replace function public.ibm_registrar(
  p_email text, p_chave text,
  p_optin_email boolean, p_optin_telefone boolean,
  p_telefone text default null, p_user_agent text default null
) returns table (ok boolean, status text, mensagem text)
language plpgsql security definer set search_path = public as $$
declare
  r public.ibm_consent;
  v_status text;
  v_versao text;
begin
  begin
    r := public.ibm_valida(p_email, p_chave);
  exception when others then
    if sqlerrm = 'BLOQUEADO' then
      return query select false, null::text, 'Muitas tentativas. Tente novamente em 15 minutos.'::text; return;
    end if;
    raise;
  end;
  if r.id is null then
    return query select false, null::text, 'Nao foi possivel confirmar sua identidade.'::text; return;
  end if;

  select versao into v_versao from public.ibm_consent_texto order by criado_em desc limit 1;
  v_status := case when coalesce(p_optin_email,false) or coalesce(p_optin_telefone,false)
                   then 'aceito' else 'recusado' end;

  update public.ibm_consent set
    status         = v_status,
    optin_email    = coalesce(p_optin_email,false),
    optin_telefone = coalesce(p_optin_telefone,false),
    dp_exibido     = true,
    texto_versao   = v_versao,
    telefone       = coalesce(nullif(regexp_replace(coalesce(p_telefone,''),'\D','','g'),''), telefone),
    respondido_em  = coalesce(respondido_em, now()),
    atualizado_em  = now(),
    user_agent     = p_user_agent
  where id = r.id;

  insert into public.ibm_consent_log (email, status, optin_email, optin_telefone, texto_versao, user_agent)
  values (r.email, v_status, coalesce(p_optin_email,false), coalesce(p_optin_telefone,false), v_versao, p_user_agent);

  return query select true, v_status, 'Resposta registrada.'::text;
end; $$;

revoke all on function public.ibm_valida(text, text) from public, anon, authenticated;
revoke all on function public.ibm_autenticar(text, text) from public;
revoke all on function public.ibm_registrar(text, text, boolean, boolean, text, text) from public;
grant execute on function public.ibm_autenticar(text, text) to anon, authenticated;
grant execute on function public.ibm_registrar(text, text, boolean, boolean, text, text) to anon, authenticated;

-- =====================================================================
-- SEED: participantes APROVADOS (Sympla, evento 3467585)
-- Somente hashes de CPF e data de nascimento - os valores originais nao sobem.
-- Reexecutar e seguro: atualiza cadastro e NAO apaga respostas ja dadas.
-- =====================================================================
insert into public.ibm_consent
  (email, email_inscricao, nome, sobrenome, empresa, cargo, industria, telefone, hash_cpf, hash_nasc) values
('julio.pereira@fazendaoagro.com.br','julio.pereira@fazendaoagro.com.br','Julio Cesar de Oliveira','Pereira','FazendaoAgro','Head de TI','Agro','63992295887','2a73660912b965848901611da6efdad28481459dea87c878a0fb2f57c7a240b7','51c991d0e42145f8a037a4b273bce5beac149b17aa79b7e78c442e36954ee2a5'),
('ricardomonteiro@maqnelson.com.br','ricardomonteiro@maqnelson.com.br','Ricardo','Achcar Monteiro Silva','Maqnelson Agrícola Ltda','CIO','Agro','34991066278','f621eaf656f2e58881b9642f90f77722b6ff71b6662a232e1e0f957178f26661','b56c94357ca88f6523f4277ac6a6dbb4db01290232b5326d3ef54c282a6e0ade'),
('josefeliciano@cofcointernational.com','josefelic@gmail.com','Jose Feliciano','Ferreira Filho','Cofco','Diretor de TI','Agro','11982242245','d49f528db0802eb489504b1d4101dce02ef9a0a3393eb4869deda96efae0781d','e5e03a8100763d79465706362e133f3211fdc37abca495996e45577ee0b1517f'),
('paulo.orsida@hptransportes.com.br','pauloorsida@gmail.com','paulo','orsida','HP Mobilidade','Gerente de TI','Transportes e Logística','6298023535','45ddf2577e424c4ada228176f19220b4fea50a9bbf4b1f8a93eaef11eb0f136c','7eeadfa7ebc2541447c4022b419b012e881e7e632bea88949ca09bb6f256df01'),
('eder.fantini@jalles.com','eder.fantini@jalles.com','Eder','Fantini Junqueira','Jalles Machado S.A','Gerente de Tecnologia','Agro','62985817667','4fd5a39d1731034c3780ce0667886c0efea8434bab316607e8c7759b24705f26','1f8d803159c1863a664f5bd22b2e1e96ccb0fb0122f3ec08446322b93ff23423'),
('fabio.silva@unimedgoiania.coop.br','fabio.silva@unimedgoiania.coop.br','Fabio Antonio','Silva','Unimed Goiânia','Gestor de TI','Outros','62984029748','b640ada8f05a226f402c482b9cf071a79a7cef4cb1bc78128d216a9b3f0c21d4','1ad52b0871cc9199dc33e6ef43747e76fa1d3fe988948d5ec365dda2e215a5bd'),
('isrel.ramos@grupoconceito.com','isrel.ramos@gmail.com','ISREL LOUIS','RAMOS','Grupo Conceito','Gerente de TI PMO e Inovação','Agro','64999691582','27b96f81923fa4ef3d5c2b4030296fd50871fdbcb0f71d5055876c2d73880cd2','3e3f1d8747b0d122a782f01a97dc0e4d083f2b284bbc5137a45451ccca36c29a'),
('daniel@consciente.com.br','daniel@consciente.com.br','DANIEL','HENRIQUE NUNES PERIM DE PAIVA','Consciente Construtora','CIO','Construção Civil','62993811515','ce6f3c66024a6ce12c30addc01b44de2878084ac0282ce7d8be1675f9763fc33','7dd5e6166abfb37d281d1edc81c9bc441730b5a866e69b4a1bd696adae13ee41'),
('getuliojunio@flavios.com.br','getuliojunio@flavios.com.br','Getulio','Araujo','Flávio''s calçados e esportes','GERENTE DE TI','Comercio Varejista e Atacadista','62991272067','c03d16aa69dfe85a1d0e53f69f34af31f17a002a5827eed992751f4272bcfb5a','3794a4b892749d9fdf57ede464c58df289eb0609fb1b5f0541dc097ac739ee77'),
('wilber.silva@novomundo.com.br','wilber10@gmail.com','Wilber','Silva','NOVO MUNDO SA','GERENTE DE TI','Outros','62992993776','d8106064bd5f5067eb6ead22f5c143b277d026c1416d866993582b0fd159b4a5','dc30eeee1417f29536951a3afc5f21cd8bdba4891ba93c3bba6a719895849f52'),
('ti.gerencia@peroladistribuicao.com.br','louceiro.ti@gmail.com','João Paulo','Oliveira Louceiro','Grupo Pérola','Gerente de TI','Comercio Varejista e Atacadista','62985477822','e35d2cc065caacfd2aa6a3cad9f1e66bd4ac43b88f1ed5fba5ca45e7b4720d98','b2278f7da4576f589ecfbab1d333d95bebc8a246a19e5cd922e9471aeaee4300'),
('lucas.mendonca@grupoluizhohl.com.br','lucas.mendonca@grupoluizhohl.com.br','Lucas','Mendonça','Grupo Luiz Hohl','Gestor Corporativo de Tecnologia','Agro','62996871414','cf8dd7a481ed5515a02a9764b933434135a42039cfcee731aeafb830c68ed7ac','9854809a1348fc5d18377d1fb80bf5432d523ae7f6a977bce9c70704ac055ea5'),
('lucas@jobsa.com.br','lucasgyn30@gmail.com','Lucas','Gonçalves','SOLOTEK FERTILIZANTES','CIO','Agro','62991475003','0d30a3751829aaa7ac7d2c6a83fc9ef021c38fd3d6a80dafc4d969125504a6e3','13f59c64a331d3689d43632c8de0120e7a07f12fe5ce8846ad33770e49c18c45'),
('alan.figueiredo@junco.com.br','alan.figueiredo@junco.com.br','Alan','Figueiredo','Junco','Diretor de TI','Industria de Alimentos','34998965663','8d5952ee5488d343b0c5e4f3b97e26fd0574fe015223b61df1f3d6a15085af97','94810273b313144e0f6d123e6effd0d7935060a98cbfd48f73594e13d216b06a'),
('wsoares@brasal.com.br','wsoares@brasal.com.br','Wanessa','Soares','Brasal Refrigerantes','Gerente de TI','Industria de Alimentos','61999763476','274cbc63f3b7a0cd64d5591f3e2bcc1eea55aec7cc764fa07eaebb70479ed184','9e9ca7a38ce59fb648972c548ca01ea2f5f3545c42b470bd2851ee5e73a8deee'),
('cintia.carrijo@comiva.com.br','cintia.carrijo@comiva.com.br','CINTIA','CARRIJO DUTRA','Cooperativa Mista Agropecuaria Do Vale Do Araguaia','Coordenadora de TI','Agro','64999543319','26c690feeab3f0fdb437c655b9d3b94e2b962045a9086e77c3825e91fee0432c','8876330650ba4bf06bbb3b1250479a532f99ecacab39e319eedefaf55392fd11'),
('murilo.goiaz@tvsd.com.br','murilogoiaz@gmail.com','Murilo','Goiaz','TV SERRA DOURADA','GERENTE DE TI','Comunicação e Entretenimento','62984329302','7bffb3f482c22df374248c6b222e8b795cde9879dbc00dfa5e131d8054b045af','fd90a59ed11524a52c3934b1728a61d29bc841849395bcb26f0cfb0f591a6ab9'),
('edir.junior@grupojosealves.com','edirantunesjunior@gmail.com','Edir','Junior','Grupo José Alves','Gerente de Sistemas','Industria de Alimentos','62981069600','58e9bbd8879768042d9dbac105cf65f4811b81c9bea1a5dc0f65bd6bd71b409a','7ae62cacb764604eb2b0e880210993d71b3eafbb308ca2dfab9563d514c297d0'),
('laerte.marroni@bomjesus.com','laerte.marroni@bomjesus.com','Laerte','Marroni','bomjesusagro','Diretor de TI','Agro','66996046917','518e002c6f592af0493c9feb0ae58caca58e80199afab4b5d6fbe4ba99aaaec6','3073e2fd92faae8c5312f3feb52aaea25bab182d7b2a910bd4be435d44957bab'),
('marcos.golfeto@rebic.com.br','marcos.golfeto@rebic.com.br','Marcos','Golfeto','Coca-Cola Refrescos Bandeirantes','Head de TI','Industria de Alimentos','11999816880','fda8369c97e14e9db749d894f1cc453087c331706caf5fe7c64543b298187b03','bf5a5a84f8bc9cc2c73962a0663cedb74556ae3996a2195614fc2f7e876fc796'),
('gabriel.silva@nelindustria.ind.br','gabriel1412@gmail.com','Gabriel','Martins Silva','N&L INDUSTRIA E COMÉRCIO LTDA','GERENTE DE TI','Industria Química','62999067623','4b2012789191d9d71a31aed47d96f19e7a5777f124ea628f257b65be544ba7aa','929a290efc28160549df13d4633512df9174b55ba42f52f72ecee730f764865f'),
('daniel@belcar.com.br','daniel@belcar.com.br','Daniel','Araújo Oliveira','Grupo Belcar','Ger. T.i','Comercio Varejista e Atacadista','62984781106','d871c8563815351dc8f66aa9b946aa09d19e32efd77d3b0a77671cb6e2a322f0','f87dd291bbacbe455fe07ee7c3bbf7a86b3c69789b448df6b25b8e093d2f70c2'),
('massay.costa@boasafrasementes.com.br','massay.costa@boasafrasementes.com.br','Massay de Oliveira','Costa','Boa Safra Sementes','Gerente de TI','Agro','31992763518','48ae361afb42a3b5e2c1e062961a105d7d86c4700798bdbd8839e039027362c5','e9e1e1b7128df04162a51bd4f7dd64dfe74583afec2227602700c7c026a5dc26'),
('rafael.sugiyama@agrex.com.br','rksugiyama@gmail.com','Rafael','Sugiyama','AGREX','Gerente de TI','Agro','11991805066','c3723227e59e2414896473253f9c9eb98780fdc5fe8ba8f3471dc5c29821c991','d4c70a7017f2f6031d8026ebfa6c3dbcd2ef4ecd186997f24c2cbe5bc2b43811'),
('gustavo.lopes@uniceub.br','gustavogrsl@gmail.com','Gustavo','Lopes','UniCEUB','Gerente Executivo de TI - CIO','Educação','61981181113','596e1a708a3b86ffbdc8b43bed5f4d97653b015c348b3e493157faf8c70d0c88','5ed0317b5d46255451e5e4e89e1a865f2932fb91a4956b353379ef80fe88066d'),
('daniel.camargo@superdonadecasa.com.br','daniel@cyberdaniel.com.br','Daniel','Camargo','DONA SUPERMERCADOS','GERENTE DE TI','Comercio Varejista e Atacadista','61981199756','bdd4fb1a54fc1c0e97390ef3b9b61611b270df83f5b7c0e8f88c5ae283487ef5','c28372a41bbf123af70cc0e6f92c5af7143bba215440312dd9d5320804347b94'),
('alexandre.santos@grupojosealves.com','ssantos.alexandre@gmail.com','ALEXANDRE','SILVA DOS SANTOS','GRUPO JOSE ALVES','GERENTE CORPORATIVO DE GOVERNANÇA DE TI','Grupos Empresariais','62999257451','8add8d0ee434912194727c292818847947c1f80185c6bfb6e726c5ef47c9e9fc','a1153db6590342c21c4ff7c6109e87e88393528213c469837114d41aeffb7b43'),
('tiago.castro@grupofarroupilha.com','tiago.castro@grupofarroupilha.com','Tiago','Corrêa de Castro','Grupo Farroupilha','Gerente Executivo de Inovação e Tecnologia','Agro','34999093437','057ae8fe2a0f03bd6e1dfa1b063785589f10df1bd7c2f8c7e87a871c64bb2164','fba3b0a506ffcb52a61968614ca317d4711467625b7dd7f90bb45623654bfe37'),
('tiago@belma.com.br','tiago@belma.com.br','Tiago','Dutra','Biscoitos Belma','Gerente de T.I','Industria de Alimentos','62991785210','0dbf7c77ab27108c67975bdcd221325ada58e1ac3ffdee715748af79eb175681','5a9f1317707dfc3575a83c2f355182c423adaed23e3dc90f99ec6455a1e9cedc'),
('adalberto@garraonline.com.br','adalberto@garraonline.com.br','ADALBERTO LÚCIO','MESQUITA','GRUPO GARRA','DIRETOR DE TECNOLOGIA','Comercio Varejista e Atacadista','61991685580','6a4150aaf77998e04d9312e42bd0652683a05a37095366c6596615c4e029857d','ee2017f46b3a2ed8df30d6eb9a55da626acc48efa675e61f68a4c797440bec4d'),
('abel.silva@ebm.com.br','abelhsilva@gmail.com','Abel','Silva','EBM CONSTRUTORA E INCORPORADORA','GERENTE DE TI','Construção Civil','62984151955','0890ed66cf025a97facfc9351740e770778829149343d04d8ba4fcf4ee3bd7b7','d4f75a163b5b41cddf4ab71f400c899463298c186ef227432404675ba8c62515'),
('andre.cordeiro@vitamedic.ind.br','andre.cordeiro@vitamedic.ind.br','André','Cordeiro Macedo Maciel','Vitamedic Indústria Farmacêutica Ltda','Gerente de TI','Industria Farmacêutica','62996648484','4aa814df2c65a3fa62ad494108e50564f11a31d38f7aded3bb575ceea4be08e8','fc5240c4033cd9677cef50a37c8e98c9698f468266674afe0fb9d38a5e6184b5'),
('jhone@jbjinvestimentos.com.br','jhone@jbjinvestimentos.com.br','Jhone','Divino da Silva','JBJ Agropecuaria','Gerente de T.I','Agro','62999015900','6ed5a911c6117bda78f5932a8df71196357255cddd92673a44414d5ffadf84fe','b913a824f0ebecefcf57118169637f17090a6ccf7a01bc9a6d53709382276a9b'),
('gilvan.sobrinho@hypera.com.br','gilvan.sobrinho@hypera.com.br','Gilvan','Sobrinho','Hypera Pharma S/A','GERENTE DE SOLUÇÕES DE TI','Industria Farmacêutica','62994166978','26574d51ee4cb4f11df5661b62d12fc18983cd57ac3c0fd13efad5e638f264d7','4e6050f041c8e3a25c59d5ef09029f1914e98b34ef8a8a80cb0c36de39608227'),
('alexandronunes@fuioka.inf.br','alexandronunes@fujioka.inf.br','Alexandro','Nunes da Mota','Fujioka Eletro Imagem S/A','Gerente de Infraestratura','Comercio Varejista e Atacadista','62984812408','9315c5c99a25142aa4082722d34006d411673a7c0a02abc70ea736ad09e61eff','95dd12376fe5eea27c42cd2644fc4883bc1f0e9e6fcf0138e5e2f2b26fe4752f'),
('fernandofanizzi@fujioka.inf.br','fernandofanizzi@fujioka.inf.br','Fernando','Fanizzi','Fujioka','Diretor de TI','Comercio Varejista e Atacadista','11999319687','62edf4201ca32385eeff25d3efa6a8d5349c5b9938975621035ffc0a0d366934','57328710ed7a9c5f29decd1bc0777da3b3346096003c569b3c556599cde25e92'),
('eduardo@sarah.br','eduardoamemiya@gmail.com','Eduardo','Amemiya','Associação das Pioneiras Sociais','Coordenador de TI','Serviços Públicos','61996063300','a65ed5af65d21f9931aef3d3306dcf237c5002b26f6d3d6c9d6ee0411cac3e6a','93e27d85e37b5a9fb55405ebdd7b5a70f5c5cb129804651bd65d85ecdc6762cc'),
('rafael.barbosa@halexistar.com.br','rafa.souza.b@gmail.com','Rafael','Barbosa','Halex istar Ind. Farmaceutica','Gerente de TI','Industria Farmacêutica','62998417166','eb2f7a3e151261148c85ca1b62dc738f0f0af58be3b0b1b3a04710f657f4847d','da0bf87f40e98abfbc7682920b979897d968b8703097f2804b931cc299def968'),
('gabriel.sa@grupolagoaquente.com.br','gabriel.assis.sa@gmail.com','Gabriel','de Assis Sá','Lagoa Parques e Hoteis','Gerente de TI','Outros','64992569046','038e7033e675e0ca8e7d309a875bea894a88670086f869ca8bf3d67413e3d5b1','373c971908dcd1c24baf534f7e1d78166be4f72a1e8ac4fe0c622114a03268f7'),
('luis.duarte@gjccorp.com.br','ldrl0708@gmail.com','Luis Duarte','Rodrigues Lopes','GJC - TV Anhanguera SA','Diretor de Tecnologia','Comunicação e Entretenimento','62999782496','0b305b5c4ecc67fba3680e1c0a901afe7d8d20464d23933611ae542f3419cb36','747851f25f5bc966c02b906b5b21c8f3262bf73729fcb1798150ef8656177424'),
('aver@coopavel.com.br','aver@coopavel.com.br','Rogerio','Aver','Coopavel Cooperativa Agroindustrial','Gerente de TI','Agro','45984043740','05a89052f4d503e4498389fb184f2dd887bf6232a09cce5db140a1421a86883a','1b28287a2e083a77b3bc05b8bc9f0777f3ba456b7ea563a46a9b5ab2f2e02913'),
('guima0964@gmail.com','guima0964@gmail.com','Sebastiao','Guimaraes','Vólus Instituição de Pagamento Ltda','Diretor de Tecnologia','Outros','64984363657','e5437162d7c9624a5c7c559078f1a01b9f99b1293a1a1437247c75528d248e2f','e3fc21077dd9af94c1f764a6ef36f8b21f359e16ce329accecd92942cf12fc16'),
('renato.machado@valori.com.vc','renato.rma.gyn@gmail.com','Renato','Machado de Araujo','Valori LTDA','CTO','Bancos e Serviços Financeiros','62984228663','c7b4814df5f1e62f4d6bb2e4a7e7feb44317036ae317f0c8f0c5ee964754fa57','f1132a87c66e40426d0b14a6bed02c6e91e7b8418a3010f4eefac3dd845e928c'),
('rodrigo@sementessaofrancisco.com.br','rodrigops2009@gmail.com','Rodrigo','Pimenta Scaloppi','Sementes São Francisco','Coordenador Ti','Agro','64999582921','7ca5836f3173e517e17f52ea63e2107014b3afe288b1b3eae0598b266e004391','9428e33ea013c5513511045f6a3e292327cf515f79d032c2a247384aee374d8b'),
('rafael.araujo@gruponatureza.com.br','rafael.araujo@gruponatureza.com.br','Rafael','Rezende','Grupo Natureza','CIO','Comercio Varejista e Atacadista','62991368035','ff82d25f679482f8a8c474cb74962fc3b3680a4de135f7d6ae8accefd1c1aa37','4317653941f42a05285157811891a4d614bb1399f03b19f302346a41c1852fee'),
('renato.guarani@gavresorts.com.br','renato.guarani@gavresorts.com.br','Renato','Guarani','GAV Resorts','Head de Tecnologia da Informação','Outros','62996128539','3efc3b555132063142027e9b435f6b2104e04ccd7e970e60a08b12cee4fc641b','5515d899078fa8bcfe4e1d0da86bbeae99008d2b5edd5ae1929adf3cf07d4ee6'),
('flamaryon.borges@rennova.com','flamaryon.borges@rennova.com','Flamaryon','Borges','Rennova','IT Manager','Industria Farmacêutica','62993991863','ab71142c82b8d3d4c1ac34836bc98d32987baa220f82a14683b7d545bf57de28','2aadd10ad8d6dd314fa8490b0555960f8ab44023cccb3bface819f4b540020aa'),
('leonardo@odilonsantos.com','leopereiramorais@gmail.com','Leonardo','Pereira de Morais','Odilon Santos','Head de TI','Outros','62991138236','5806654f9563a369d9fc8fcbc4e99c1a576199a941bcaa8c5183a6d89627d630','7818c6d605d3acc6323d8a257d8425d0541d840c4d1cdd62f141e834d1bd7057'),
('lucas.silva@uisa.com.br','lucas.silva@uisa.com.br','Lucas','Silva','Usinas Itamarati SA','Gerente de Tecnologia da Informação','Agro','34992110666','fa4fa07f37872c0252aa3c3688e6d3ccf9f6ac29e4ab5549bf03eba0a9eeaede','85f30668c96579c56387b927f53a6d8f74b1df247c07c16cdbd73d3b324138dd'),
('airton.balthazar@grupojosealves.com','airton.balthazar@gmail.com','Airton','Balthazar','Grupo Jose Alves','Head de Infra, Segurança e arquitetura de TI','Outros','21994646987','4e3353948ccb7d6b7d9aeff15e868693b02efcefbb9e81779501b2c4ba20c600','6b9039d5ac6da6631a914d8dffe625e3513799112a66aaaa4f59b69d30d8ed52'),
('izaias.gomes@piracanjuba.com.br','izaias.gomes@piracanjuba.com.br','Izaias','Francisco Gomes','Grupo Piracanjuba','Diretor de TI','Industria de Alimentos','62999739480','6b243f9c4560065772a58f66ed74893c7dca07b98afe7dfc47e80e3148376021','8ab162598c65f9b36eecca8d72b24744c374e4a092e5fc3851a82ac1aa81214d'),
('bruno.paiva@unimedrv.com.br','brunoluizpaiva@gmail.com','Bruno','Paiva','Unimed Rio Verde','Gerente de Tecnologia','Outros','55992383770','8ed8337ea60a4d55157fcde067ebc7fb09ed9dd68527053c021198891785a418','825514c0489c8a43e5efda43904ebd70db3ce371bbbac52bbdb8c334b0fc960e'),
('rafael.pinheiro@gruposinova.com.br','rafael.pinheiro@gruposinova.com.br','Rafael','Abreu Pinheiro','Grupo Sinova','Gerente de TI','Agro','62985240212','f4d4d2a78d4d1c7272c25be8bb52a12dfc19e6fb1ed819990313786dcd0d9622','93e432bc2bed63bd35401de5d662628012e6db2a60cbe4e148fa8b0f31a7a92b'),
('borges@sementesantafe.com.br','rozenraurio@gmail.com','rozenraurio','borges','Semenntes Santa Fe','Gestor de Tecnologia','Agro','62984999122','a3b3505765ee101f6db6032978bbe51eca761d7d371a754ccb70b6ba9aea8667','cf6b6404e61fd2d13c820d484c45d9c14fa1a8066b9e736353c7c365a3c995ab'),
('lincoln.costa@innovapharma.com','lincoln_costa@hotmail.com','Lincoln','Costa','Nutriex','Diretor de TI','Industria Química','62992459441','f98162f6d1b6afdd391714fbe7da024704967b93d06acb27a5fb4a9f7ce49bdd','86c7b8e61d35620b8c79c4cbe9d8042ff45c3127e342f20dc5061e9b345c04d4'),
('washington.cabral@tatico.com.br','t.wallys@gmail.com','Washington Luiz','dos Santos Cabral','Supermercados Tatico','CIO','Comercio Varejista e Atacadista','61999766579','2d330553cfd24b47552c725e473f9c35368923bf90b78d5ba7a0b4d0ec6b78dd','e96f66f90dab9a1f89e2c8e4d5858db7f5006d9126ddf3699bce98466a8dcf71'),
('renato.canedo@complem.com.br','renato.canedo@complem.com.br','Renato','Canedo','Cooperativa Complem','Gerente de Tecnologia da Informação','Agro','64996480488','769617b2663742b9ea68edfe5e952407aa8509d8d654d08ac659cf0987277a91','8ad42a00c7547cd5c9944f6323df425184a0eed4dd460965d3e525f0ed8c4663'),
('tecnologia@shcosmeticos.com.br','tecnologia@shcosmeticos.com.br','Alberto','Pedro','Shopping dos Cosméticos','Gerente de TI','Comercio Varejista e Atacadista','62998310801','184983fd0e536a09279c53baebcfad9b637d53c4bc7c5a568733651c269d157b','b3fba5d96ffc920ed7d3641e614d1cea24977a4ba52643e196ec4dbdc9badc91'),
('laiara.gomes@ciplan.com.br','laiara.gomes2@outlook.com','Laiara','Gomes de Souza Nascimento','Ciplan Cimento Planalto SA','Coordenadora de TI','Industria Outros','61999732991','0d504c8a28aff877489d577510f18a90f8c2d8e58ffb2765def8bc8fd7ab626f','37d3d59503a9c9bfb6cf289fdc126674a757f503ae565323f3f65e70e2ad25c1'),
('vinicius.faria@stoatacadista.com.br','vinicius.faria@stoatacadista.com.br','Vinicius','Oliveira Faria','Atacadista Super Adega','Gerente de TI','Serviços Públicos','61996443738','7c933e203cb06d569dd194297fa6a4cf94a9ddf9de6c742f7b36e54a53e5aa55','6a1d6dcf7a215721e98ae6ea01eed167b0329ef5f88b18a16056148d3e81637a'),
('pedro.miranda@ssa-br.com','pedro.miranda@ssa-br.com','Pedro','Miranda','SSA','GERENTE SOLUÇÕES TI','Agro','62996116676','f9b7f9b794ce8ebd5b6250e2da1f19edca18d06c5b5396346f80578ee28fd15b','d9e8de2f6b834fc00b3c8d563e06ff0e0c0eb7185f7a10df5f513f69791d3278'),
('kaio.fabio@terral.com.br','kaiofabio@kaiofabio.com.br','Kaio Fabio','Sousa','Grupo Terral','Gerente TI','Grupos Empresariais','62984000575','0bb763f9c4788abbff2327d1d7bea6ba0b50d73c194bfc186443199dced37eec','1d464cd9e6447746c5b809b7275a99930fd10dcb76258c9f9951938be37ff58a'),
('rodrigo.backendorf@ciplan.com.br','rodrigoback@msn.com','Rodrigo','Backendorf','Ciplan S.A.','IT Country Manager Brazil','Construção Civil','61981331253','dd70c21d9fe5071e50de604f04fd0a3a98f5098e2a2e109db0666c4ce2574761','57ce228b95b61ce4e2cd855a70d72c4753de306293f4f2d4b3de7fd5791dc7a0'),
('elias@bigbox.com.br','elias@bigbox.com.br','Elias','de Deus Dias Oliveira','Big Box Supermercados','Gerente de Tecnologia','Comercio Varejista e Atacadista','61991946992','3cb376d89323efaf7038deed83c96076d9a7f67df7917f26dee470db138c2135','f9969595074ce0f9208f8c1d0afee6da190ebb80eb888013c0eb0ae626428172'),
('fernando.moura@gruposaga.com.br','fernando.moura@gruposaga.com.br','Fernando Luiz de','MOURA','Saga','CTO','Comercio Varejista e Atacadista','62992351007','0e5de4341c702e1158b7ef75fb5a922ee1cbf9698027e6a773ae343e7d0a71fb','39354bbe756ccfc007c0c1546400792b752c0c1812db0aebd3c407c0a2dea977'),
('osmar.junior@moreira.com.br','osmar.junior@moreira.com.br','Osmar','De Oliveira de Jesus Júnior','Supermercado Hiper Moreira','Gerente de TI','Comercio Varejista e Atacadista','62982467649','d8e8e519aaa7c6041ca64e6b5d9e43f41686f5fcc373514900220d267b23d4a4','1bdfecbf93be9bc2b361ef943fe6d07caa20b937e2f1c1413781dee49708a386'),
('alexander.valerio@casaeterra.com','alexanderpvalerio@gmail.com','Alexander','Valerio','Casa e Terra Empreendimentos','Gerente de TI','Construção Civil','61981790092','e78f4e92c4ac57bccc25e51be9ed526fe7ef6039cdbc4a4b1687a378c7e82547','9d9369928a72704c64067adc8c76206948a20b5273ae2fc12c4060dfc5d0575c'),
('jose.junior@daus.global','juniorzecarlos@gmail.com','JOSE CARLOS','DA CUNHA JUNIOR','DAUS INDUSTRIA DE ALIMENTOS SA','SUPERVISOR DE TECNOLOGIA','Industria de Alimentos','64992638605','62f8ee43afcf09c20fc4ba8c9d7a8cc7327bcfe8b9157c7e7c79e87bf26cdba5','4431228a8e4134aa956053d5dd372648e5e3998e4b58894549a5d1f0fc962eae'),
('fernando.nakade@caramuru.com','fernando.nakade@caramuru.com','FERNANDO','NAKADE','Caramuru Alimentos S.A.','Gerente Infraestrutura de TI','Industria de Alimentos','64981286641','ebb889d163b9835973d0177adac8dbbc818f277281ad8b83348922cf11bb3bc3','0020cd29bd13185fafb1307a60208f85a40279e53f50c9456e4242216205edac'),
('dleandro@brasal.com.br','dleandro@brasal.com.br','Daniel','Leandro','Brasal','Diretor de TI','Industria de Alimentos','61986020636','859b6f32ad66fdd54bb945a16556b72e61d2cd174e533b9da2a7f4c083198572','d60a4b9af91314b7668b85788d71c3d5a90f0cb862f2d9927efb5ae231a9cbe8'),
('cresio@patriaa.com.br','cresio@patriaa.com.br','Cresio','De Souza Pereira','Grupo Supercei Bellavia','Diretor de TI','Comercio Varejista e Atacadista','61996941234','169a2ae6c34dc1770ee5b3c64ca9157131f4510077cb5b2fce7efc6f36ff38ae','83aa470c50b4a829d8da6ff57b3e9ed441872ba5018296799142ede74b5bc848'),
('marco.souza@funpresp.com.br','marcofragososousa@gmail.com','Marco','Fragoso','Funpresp','Diretor','Bancos e Serviços Financeiros','61991062734','8f470ebe93d972a82bdb972bef0439af4190fbf0f571f80cd11e13611b18432d','0bd55df782dcaac8c539cdf0a96f53b8f10fe7257a3861edfce50d731ae96627'),
('talassa.vieira@agroamazonia.com','talassa04@gmail.com','Talassa','Vieira','Agro Amazônia','Gerente TI & Projetos/Inovação','Agro','11956292403','c172451ba9f1f6cdbf55ae2336ed8050aefeec1892d064012b6cf58132d8d393','ff1f8eaef19717e3a1e18631d908454adf28801df41ad51d75bd6a376c247ff1'),
('jean.braudes@araguaia.com.br','jeanbraudes@hotmail.com','Jean','Braudes','Araguaia S.A.','Gerente TI','Agro','62982872095','e583e1d8478d3f9e1cd25744e36144e9e99cf1a32584e8ba3e3531f2e731608b','2d2351deded41503e6eec13a00b9378dad680201b55b96c458d561fd0267fd2e'),
('rodrigo.comparini@diroma.com.br','rodrigo.comparini@diroma.com.br','RODRIGO','COMPARINI','www.diroma.com.br','CIO - Diretor de Tecnologia','Serviços Outros','64999491795','01abfd0a5e48e41fe36f8e1066bffa0d5bd322b9ea8265a4f430b20463493a75','51caddc8931d10e6253dd44a06ea031ace66df01f44011c4efe341a460e09cac'),
('renato@caramuru.com','renato@caramuru.com','Renato','Pereira de Souza','Caramuru alimentos SA','Diretor de TI','Agro','64992948337','f470129c3a984c130713c9166a27ddcb0e5a467bdaf7cd2f32a568b42c10cab7','860d8b0377212a3aedd461a2f65a95bbb90ae3690ee175574154ed0828a959a3'),
('pablo.assis@cscresult.com.br','pabloassis@gmail.com','Pablo','Assis','Valecard','CTO/CIO','Bancos e Serviços Financeiros','34999627606','963d3e9bd3db8028eba7a2366e4c256a4f8594e7f867c5ff25485a1f9792a4f9','7dd3f337f5b05169143dc6858486a7d0f43712c2d64bb0a41fdd73e778550886'),
('icaro.chaves@barralcool.com.br','icaro.cunha1988@gmail.com','Icaro','Chaves','Grupo Barralcool','Coordenador de Tecnologia da Informação','Agro','65999871226','362b482e7c3fffa5de548114bf2335ca1e6e457d74486dab48c67ffc785865de','e0d0b0630f3242944537a066d904ba1b40e4fea90a7de9ae24fc4cd2de62cf4e'),
('rodrigo.goncalves@uisa.com.br','rodrigo.goncalves@uisa.com.br','Rodrigo','Ribeiro Goncalves','uisa','VP de Gente, Administracao e Inovacao','Agro','14997462929','20db7f1f468904b1ec99a5a3a8bad3252a522b2c5d1364b663fb2366ffaa185e','3e8f969af8c58dae80bdce2c89c0b9742c3e202eaf2b29f22b38e2ae1e49ebab'),
('joao.gilberto@piracanjuba.com.br','joao.souza4@hotmail.com','João','Gilberto','Grupo Piracanjuba','Gerente','Industria de Alimentos','62999454917','f8740711252d3dd29f78439228128c3e551ed7ae3386b9cf0512e2a4ec5f6706','af983b121c09bc5f496b7933eeb0e7d5591d55e2ed454c331c5672484d808383'),
('italo.ridney@metropoles.com','italoridney@gmail.com','Ítalo','Ridney José de Barros Rodrigues','METROPOLES','CTO','Comunicação e Entretenimento','61981651775','bbe5609836032e670c85604f2b6894ac0b135b4947d419c82f002af502f946cb','f11b3db7f8e2292507b2b09ecac3e13f96af5fe308ea66204310117c4383c6d4'),
('igor.nunes@grupofarias.com.br','igor.nunes@grupofarias.com.br','Igor','Nunes','Grupo Farias - Usinas','Gerente Corporativo de TI','Industria Outros','11933030497','bcecf7fb3673dcbe37a9595e4c7778c802101e25fb82602b189411b49d750615','6a008ad7dbaa74a7884ef11f0d1273ac7fdbaed1c20e0dd09c4211b22ce98017'),
('giovanni@bestwayseeds.com.br','giovanni.a.sena@gmail.com','Giovanni','Anício de Sena','Bestway Seeds do Brasil S/A','Gerente de TI','Agro','34992009500','98838d23c606f0f733360d90099823e5b82a873de719f22badc02b0a7eaaa1e9','2adcaee4e66e504dfba7f9b8f44c82c23ad8da952c0242fe1e5887d2699efbf5'),
('helton@martminas.com.br','heltonglima@gmail.com','Helton','Gonçalves Lima','Mart Minas','Gerente de TI','Comercio Varejista e Atacadista','31998020285','de72f094b01a88d39ef2b93858efb64758e1995ae57a4312f3e1730640cb7693','3f3aa62e3c56ad13a8b65bb6dc642099a2a4c8e0d2cdfa25fc7f8ffec9c196cd'),
('george@scala.com.br','george@scala.com.br','George','Pucci','Scalon & Cerchi Ltda','Gerente TI','Industria de Alimentos','34988020075','8b579197080f116b2c3f503496b0ac61e9f519ab3c422366472059d884c52555','a2c5f0f53ebd3db5f55552cc8380e4e7061b3691f43bd8822f9eded166406cac'),
('ronivon@jorlan.com','ronivoncruz@gmail.com','Ronivon','Cruz','JORLAN S.A. VEICULOS AUTOMOTORES IMP E COMERCIO','Gerente de TI','Comercio Varejista e Atacadista','62981537080','169d38f2909a889b3f8b09db25b0e36ce1b47a19126962874a90aec7189c6b9b','214932c89d7dad320e1ceffe6955e15779098262f5a3e636488950a377cb4628'),
('karinne.torquato@novaeranet.com.br','karinnectorquato@gmail.com','LUISA KARINNE','LIMA CARVALHO TORQUATO','Mercantil Nova Era','Gerente de TI','Comercio Varejista e Atacadista','92986209946','ed9abe48aed6ed30bb5126dff1ccfa22157f9604e1218052976331f638617062','b9976f514dca0813f48c591ce75e753d59cedce1475ab67abb935c2794cc3559'),
('ledir.malaquias@usinacoruripe.com.br','ledir.malaquias@usinacoruripe.com.br','Ledir','Malaquias','Usina Coruripe','CIO','Agro','34999790797','51c7dea836a1d1cf4c9f4cdede3844a36ec50cb70cd19c75b25d4a7d383859cd','f57c0d6890bfb8d00bba1c573651a473656c1e495128d740ddc247b41f431b10'),
('dmares@lineaalimentos.com.br','dmares@lineaalimentos.com.br','RODRIGO','DIAS','LINEA ALIMENTOS','GESTOR DE PROJETOS','Industria de Alimentos','62992593962','c504cef7180376c2b9a473803b89d22b5883c29faf465ddcaf924780069a2aab','6f765ff0fa4a552786d7b95643eec6c0126c0721dd8fbb01e8c747679caf65bc'),
('carinereboucas@mpf.mp.br','carinemsr@gmail.com','Carine','Marques','Mpf','Subsecretaria','Serviços Públicos','61984530122','ab9d9c1f43c9f5723348780fac493e634e22bb9e5b3321dae549f2560e24702f','51456a6317d966df1829fb62106769dc2bd0d63d4ae1003b77443fb91f25fbc5'),
('karla.vanessa@agu.gov.br','kavanessa@uol.com.br','KARLA','OLIVEIRA','Advocacia Geral da Uniao','Coordenadora de Soluções Corporativas','Outros','61981197865','749e037a643849009e0d5e4b24a2d727beb5c100256bf60cef776267146fcbf3','8e4680288b29d1dbec31f835aa078186af216d98d82c84774826f38085f91977'),
('jhonatan.liesch@alcast.com.br','jhonatanliesch@gmail.com','Jhonatan Daniel','Liesch','jhonatan.liesch@alcast.com.br','Head de TI','Industria Outros','66999940024','f592d2a27659a7e8cdaafe27390aa15230846fa68d0e0f9978b6ec314c464844','7a36e908ed0c8481e6bec0fa06fe7ee8a9ff86d77122fa5cc9bf6d6143a4167c'),
('luciano.lopes@uniube.br','llopes@hotmail.com','Luciano','Lopes Pereira','Uniube','CTO','Educação','34999780273','d1ea2521e67625248d080e34f24e1b6f91e53b04551bda89c9bdfb09fc6ded22','2adcaee4e66e504dfba7f9b8f44c82c23ad8da952c0242fe1e5887d2699efbf5'),
('leonardorosa@jspecas.com.br','leonardorosa@jspecas.com.br','Leonardo','Duarte Rosa','Rede Js Peças','Head de TI e Digital','Comercio Varejista e Atacadista','62984273660','271b3aaaa1011bc4666fb6ebdf0defbac9e626c2f120d901597ae1a6446c82e5','88da99a85b06a4f12f6715b674b48bf6ef449a5b1e4917a562078825832ebd8d'),
('jorge.cordenonsi@aviva.com.br','jorge.cordenonsi@aviva.com.br','Jorge','Luís Cordenonsi','Aviva','CIO','Outros','11941788016','a5365ef41d7ce6b208d2b76efd9462253d6f6be3f08a19c2edca7d805cfd72c0','e261030db21ad2ef84612473cc2660b6e00a7dae32144406c8b826bd604695f1'),
('marco.gracindo@jotabasso.com.br','mgracindo1606@gmail.com','Marco','Gracindo','Agropastoril Jotabasso','CIO','Agro','11955501672','7ddda03ecaa46e63915eec8d3a9c216df2e03323b56e86b17cf5bff24c031bc6','afd1d6a72bedd1c06bed6c4a649ea2bcb3eb7e969a1cbe5a306723a8c4c3e482'),
('leo.yamanaka@copasul.coop.br','leo.yamanaka@copasul.coop.br','LEO KYOMASSA','YAMANAKA','COPASUL','GERENTE DE TI','Agro','67998254075','8ecee9c66c6593e9f1f434fdc65708924851cd1d72f36c019f6565433d78db8a','f6ea02ea2770eba2608092f9fa12c1e471994af1a37878f3160877caafe334b8'),
('dalser.moraes@gmail.com','dalser.moraes@gmail.com','Dalser','Moraes','Polato Agrícola','Gestor de TI','Agro','65981572427','606ea18831c59a82e97cb1995a0dd20d20f6d45242e27cbf7c197d30901ef7ae','f2eed3e170b7827a7c3372a813f05d6c0bc930402356b037dd331aa75c23d2a6'),
('wedmabraz@comigo.coop.br','wedmabraz@comigo.coop.br','WEDMA','BRAZ','Cooperativa Comigo','Coordenador de Sistemas','Agro','64992848846','60c2dc4925ab3ebde2e838e7c98bbf60d74e794c2ca8c4f632a9b305f0ae923f','6bb282dfebb41bae893d81e12458b0707bb058276e5618086c6aa6c249af1006'),
('thiago.almeida@afya.com.br','thiago.almeida@afya.com.br','Thiago','de Paula Almeida','Afya Participações S.A','Coordenador de Segurança da Informação','Educação','31983549316','08b3ad499cae25c8446d5aced53fc128e2c6ce3c1c47340ecf48a2c0ea702bd2','16a69980145d3805070c0167c810fb64dfd1584a9a6945e665ee7ebefd113281'),
('camilo.mussi@agro.gov.br','camilomussi@gmail.com','CAMILO','MUSSI','Ministério da Agricultura e Pecuária','Subsecretário de Tecnologia da Informação','Serviços Públicos','61981242912','8e2c28db031f7d71df22d03b4b47de7d15fa093aa5cdac1c9646c21b11188667','4579eb94dfaacf8430651434d6cfaaabfb90ed4c251ab8eecd4fa864ab7aea12'),
('wandersonfelipe@greal.com.br','wandersoncfelipe@gmail.com','WANDERSON','CAETANO FELIPE','Grupo Real','Coordenador de Segurança da Informação','Comercio Varejista e Atacadista','34999073302','e5c69386d362a1b2e15023f2ce0ea5c2dc0f866b9ad3335a105be2cec3582156','3c756b5ae7f5d26b5b34dc6484f381af69ee8972d1463a26146df3a88920717e'),
('kelvin@agirsaude.org.br','kelvin.cantarelli@gmail.com','KELVIN','CANTARELLI DOS SANTOS','AGIR SAUDE','Diretor de transformação digital','Outros','62984338196','f96802fe409e87bbf8b19157b7ae97fbcc9dcd221a4fa6e82c8d9eb1b9809e1b','8a191dd7022cc674118a2d1ba8d8e7fee1abc6dbced2f3aaac9bcc0b1ac7f6d5'),
('deilton.silva@saude.df.gov.br','deiltonbsb@gmail.com','Deilton','Silva','Secretaria de saúde do df','Secretário executivo de ti','Serviços Públicos','61986335079','92bc0ce30e3a8c72d2f612e41ca914e91f48508467a44d212c2b6f77500734b1','45faf94daf8b925ccafd318348a85cf259f366b11a1434c6fcae39d4cc74894b'),
('daniel.costa@alvoradanet.com.br','daniel.costa@alvoradanet.com.br','Daniel','da Silva Costa','Alvorada Produtos Agropecuários','Gestor de TI','Agro','67992870890','721a010976c60be6937855cc2b1b113fb89dbfb520cb0b1833243f15c40f31b4','7396318069ff4aa7b2ef76ea2e8cd4feda7a7f376a88fc26edb482a1dcd97097'),
('augusto.carelli@grupovb.com.br','carelli64@gmail.com','Augusto Antonio','Carelli Filho','VB Alimentos','Diretor de TI','Industria de Alimentos','61998791978','0acd24f4ef899706514a2e670b10f56b674094a370a896eea1e446cee7895f62','7c6fa81be622fa62e9424e0fa97d46d024d6da8d19d2fee229ae2d96cfe56179'),
('zalamena@hpeautos.com.br','ez00006@gmail.com','Eduardo','Zalamena','HPE Mitsubishi','IT Manager and Process','Industria Outros','64984012869','f41e8718f971d0a83d29fb8ccdeeff5c7e6307d8c34355ad08c0426358a694b4','a8257ddf3981f4a9e28d7d560da73418786e1dc8fc1ae2ce6f2b45d4e778ee59'),
('glicejo.lopes@costaatacadao.com.br','glicejo@gmail.com','GLICEJO','LOPES','Costa Atacadao','Gerente de TI','Comercio Varejista e Atacadista','62997017660','3432dfd3e270ec15a2dd1bec1a1233ceed39bb6371e471656da1d0518f506860','94c9c0a8ab5b46bfe5800853f9c043e444ad8cd2693ee47104e757db04f8398e'),
('oscar.costa@kingspan.com','racsobr@gmail.com','Oscar','Jr.','Kingspan Isoeste S/A','Head of IT Latam','Industria Outros','62993478291','695f8fdd37686ad1c07f7293d4c5d2414e7063a5b70db9cfe5cb68ad3bbf5b2a','9d536184e6ec00d0a74d6eab2dff7fefb6c126f2acd3d0b5240311ab021c6d3d'),
('kelson.alencar@ssa-br.com','kelson.alencar@ssa-br.com','Kelson','Alencar','São Salvador Alimentos','Diretor de Tecnologia','Agro','62991127397','1da62d9ce70757ed87a63cbac7a60d845ac430ade4d15fde703ce6c72bfa94c1','893bc5734373830cb4f86df9c830dc1a94ca5685c31c37553a03914045488953'),
('sancho@hospfar.com.br','sancho@hospfar.com.br','Sancho','Messias Bastos','Hospfar Ind e Com Prod Hospitalares S.A','Coordenador de Infraestrutura','Industria Farmacêutica','62981181282','9fb22cd04ffd722bffa2338a62b4ab6693ae76dfe8649ccb650b0cec0da98968','7afcf186cc138632d1fa041dded2e5974bc8594bd5c5652a0f55b070524eed69'),
('mikie@marquise.com.br','mikieripardo@gmail.com','Mikie','Ripardo','Grupo Marquise','CIO','Construção Civil','8587614940','2b1b363d9a91a9389750a555d2c752373c018ce76067123c08ea542d3b2c22da','a5994e2c954614e688c3029b6da27ba136d647b061a4043659e26773b81cc00c'),
('pedro.henrique@italac.com.br','phenriquecaraujo@gmail.com','PEDRO HENRIQUE','ARAUJO','ITALAC','COORDENDADOR DE INFRAESTRUTURA DE TI E CYBERSEGURANÇA','Industria de Alimentos','64996527362','00a3363c31c9b8bb9bcb4cd44430640fbc4352c21278bc3cac8b2cb00d28db1a','2ec1ae4164bbdaf8f370c542b6ec620d7a5a360cdd498b23a04504c84e3a15bc'),
('pedro.porto@terral.com.br','pedroasporto@gmail.com','Pedro','Porto','Grupo Terral','Coordenador de Infra e SI','Construção Civil','62992404465','4d92bcf81ec6e476aa3f62101f062db1a53102d86f9774e8beee991b57c6d044','0a2fb160a2089082fe024c52f4580e63a05ccddd7bb7e6e514438d3c4de74fb6'),
('ti@friato.com.br','fbailao@gmail.com','Rodrigo','Bailão','Friato Alimentos SA','Gestor TI','Industria de Alimentos','06298139114','a444c83df504d969c0f142204ce92896e6e76615aaa615c618a579496b5d6455','c2cceafcf24e70e557d3c61ef2e0a982cacacd9eb4b9a9777476ec5638bd8ea1'),
('adriano.cargnin@solabia.com','adriano.m.cargnin@gmail.com','ADRIANO','MENDES CARGNIN','Solabia','CFO','Industria Farmacêutica','47988020221','ecac19a4424441c2f48938f47cf59081dfb6e3633974223ff879f01d3898ede9','d1ffae7610c07c2b7cc9e7cd0fc1ac75c00c1154debbc13ba9591dcbefb1feaa'),
('max.pedatella@hypera.com.br','maxpedatella@hotmail.com','Maximiliano','Pedatella','Hypera S/A','Gerente de TI','Industria Farmacêutica','62981249446','a72efa77324ec6c6050480bbc34b0b4845d0808ba50ed903f9c9f68a375bf480','70f78aeb1254731064d97a51e364ab7461f389748dd5af179536f54ca3b10cc4'),
('donato.lopes@grupocereal.com.br','donato.lopes@grupocereal.com.br','Donato','Lopes','Grupo Cereal','Coordenador de InfraEstrutura de TI','Agro','64996252408','0222a10764aa140b2b9075cb52297a766996ad0a1002a365e071daaedb5b206f','9ccb4f5f1ce6a754f8227ff08ffce71af8f99cbcd0413523d54a0f1df01c2724'),
('sergio.ribeiro@avivar.com.br','sergio.gribeiro@hotmail.com','SERGIO','RIBEIRO','CostaFoods Brasil','Gerente de TI','Agro','11973135599','b414741e81aaef2abdfeefd52c747a853cf9804bd983fd2c32ece200f4c08386','03f22ad51f0ace3b0dbbaad00d0cc51e3546c57bdbf5d933d086228757bb97b8'),
('kleber.monteiro@atacadaodiaadia.com.br','kleber.monteiro@atacadaodiaadia.com.br','Kleber','Monteiro','Atacadão Dia a Dia','Gerente de Operações de TI','Comercio Varejista e Atacadista','61984916076','f332da96e158e8bed4427893183a561ebdd91b1c3dcd68c19612297f83901d8a','0726112515fc835d78ebfa892752fc2a6de8056775df5648b1083008b3e0858f'),
('marcio.cleyton@copasul.coop.br','marcio.cleyton@copasul.coop.br','MARCIO CLEYTON','PEREIRA','COPASUL','GESTOR DE TI','Agro','67999961378','a2d8c35dd20e5f7bc809f524108cde6476b00c7eb95791eec312f9ae5ec06b4b','306ffa5d63354f6aacb23bf5120c0b9e5fcf35adf733645b726d5eee4577ea21'),
('marcos.sousa@goias.gov.br','mapsousa@gmail.com','Marcos','Sousa','SEFAZ-GO','Coordenador de Cibersegurança','Serviços Públicos','62996413552','cd12f835eb331e490e99607f304646a53c07bd543d3d528dd4bce91becf0bcb2','9ff2bc95aabfbee596a510094735b16282edb2ddc9fb29485af90cdcf567a583'),
('diego.messias@trinusco.com.br','diego.mofd@gmail.com','Diego','Messias','TRINUS','Gestor de TI','Bancos e Serviços Financeiros','62999806562','acdc0cf7ed76f0104f59442ef58c98c00e4a177cd629962ae9ad1c0918cc8036','232436d0c4a487b662721197361e0c483f12303d7780ee0617bb8ee0a1b98fa5'),
('rodrigo.rocha@sfagricola.com.br','rodrigorv2007@gmail.com','Rodrigo','Silva Rocha','SF Agrícola','Coordenador de T.I','Agro','6499961446','c4d84e1d30b4efa095474eb56ab96a9da277ec7104683f9c81d481181feee370','114b5dd3ebede62020781663b788d507607a854ef6a1046a9ac5ad723402e5bb'),
('wagner.biasi@amaggi.com.br','wagner.biasi@amaggi.com.br','Wagner','Biasi','Amaggi','Head de TI e CSC','Agro','65996249397','d42c48cb2466cc23f07c866c87ce136099545a507665a5f7379808fa1c1150ba','8e4e4125b3535e610a50bc52c1fd5ff7c963d1c2c37da88d0cfc5208f7a55916'),
('luciano.batista@corteva.com','lucianooliveirafsa@hotmail.com','Luciano','de Oliveira Batista','Corteva Agriscience','IT Site Leader','Agro','61981628579','f31c71104876c36559496de8c956e3ee2b43618941e3632e2a25a38007f7bee1','3ded5b0c2ce7d7fb40689828564ba0d2a0db8b7422b72a3034b3ebd6181bacf8'),
('cleiton@aviva.com.br','cleiton@aviva.com.br','CLEITON','DOS SANTOS DANTAS','COMPANHIA THERMAS DO RIO QUENTE','GERENTE DE TI','Comunicação e Entretenimento','6499949461','b941a2d2e4579ba6c9abe98b8b77b3ef4ca1cb7be08ae559daa1e5c28b229ca5','4b92dd928f1531049c84fca33d3d60f7ebe0461e500f0e96b6fe5d9701894b1a'),
('edgard.souza@agrex.com.br','edgardbs@gmail.com','Edgard','B Souza','Agrex do Brasil','Coordenador de Segurança e Infraestrutura','Agro','62991101119','8288179ff1c54c5b0aa6054300a48300998f5eb15089c78f24ecfd876469708a','0bd7e3ce9564d74e565afa9f757017c1a9cb11daca2cb4bc0e6333fb104a6e50'),
('marcus.bezerra@i9go.com.br','marcus.bezerra@i9go.com.br','Marcus','Bezerra','I9GO Consultoria Tecnologia e Inovação Ltda','Diretor de Executivo | CIO','Serviços Outros','62992275075','d0e6d312fa2c7e94bc7a9d0fe20f33eb563e42adda6064af3f0653d56c150bd7','2c2ab1e11bbd638654effc2982255ab01b4aba8da40f64dcdec552b4ac88a173'),
('henrique@condorbrasil.com.br','henriquelima.ti@gmail.com','Henrique','Lima','Condor Atacadista','CIO','Comercio Varejista e Atacadista','61998158565','131d5a2914568fd16075bc915fcb16d03b1b6edb45797a853ce233638150bc7c','9a857ee74c8d74c6200cb70094787b63c43bb173ac9a3638372da4de56fb7e10'),
('fernando.faria@datatraffic.com.br','fernando.faria@datatraffic.com.br','Fernando','Faria','DataTraffic','Gerente de TI','Serviços Outros','62983086226','29619187b72bc43f15acce7ff12ecd5fcda0bcce3d9da0995ef8ef809ea26187','fe6ea35e95f689083903de415ebb12e02bb0e3f579b56f140be3a8d1b3989f11'),
('breno.sa@aviva.com.br','breno.sa@aviva.com.br','BRENO','RODRIGUES DE SA','COMPANHIA THERMAS DO RIO QUENTE','Coordenador Infraestrutura de TI','Comunicação e Entretenimento','64992199558','68c75b71eedc0979981051818cf70664b335da5f9bf25bd089babf009d072bec','1352a65ce3454ddd1c4e433075a8c401e9bb2c46a4708ca3483dfecdab082495'),
('andre.pompas@fluxodistribuidora.com.br','andre.pompas@gmail.com','ANDRE','POMPAS','FLUXO COMERCIO ATACADISTA DE PRODUTOS ALIMENTICIOS','GERENTE DE TECNOLOGIA E INFRAESTRUTURA','Comercio Varejista e Atacadista','61982012222','828690d51a09d416bf232ad231923fe157e80bd32430476c374736f9d980391f','c53e655163ddea5b42b9246517aa0157e3e7e44cb26f463ce70d734cce6b30b7'),
('juarez.azevedo@ssa-br.com','juarezbarreto@gmail.com','Juarez','Barreto Azevedo','São Salvador Alimentos','Gerente de TI','Agro','11996244035','cf7bf054a0720b5bafa6f457ce3e98eca15a15844b4fb0bde1646194411bb3c6','facec48ea789f3231acbc5358867fae1f5ee3f06a330ea35fdf22c16bf4c15c7'),
('patricia.souza@credirural.coop.br','patyamorim119@gmail.com','Patrícia','Souza Amorim','Cooperativa de Crédito de Livre Admissão do Sudoeste Goiano','Assessora de TI','Bancos e Serviços Financeiros','64992212985','0083aff598e4b3db2c862a2f82ef8f700303a8928b3732e536973dfe2204681f','d5da9b22da25b525bec983c0138731fbecad4bd2ee5afaaad73971e83f64e5e2'),
('braz.martins@hcompany.com.br','brazjuniorgyn@gmail.com','Braz','Martins','Braz','GERENTE TECNOLOGIA','Industria Farmacêutica','62982020004','58a418e6e8c1c5ab0eedbef56163ce84e4a976870866d54437952de5a9c1d828','3c41ad701ebee36bca03e7a5657a5e577acb6f1ea99fac1e0508dd324bc84b3e'),
('jania.braudes@piracanjuba.com.br','jania.braudes@piracanjuba.com.br','Jania Madalena','Braudes','Laticínios Bela Vista S/A','Gerente de Operação de TI','Industria de Alimentos','62981184695','d4772cd377b1a7a7b8d980c66fbab22177a49a0ce69cd05d94e161cab38d56c2','73bfa48413e4953da1ed329723914316e5e374dbdd085843a27cd7215263e42c'),
('ti@radiologicarv.com.br','leandro7fm@gmail.com','Leandro','de Freitas Martins','Clínica Radiológica de Rio Verde','Gestor de TI','Serviços Outros','64996750047','81d3de1ba16c47b3e6d031006b90eab6f54c84917924493e346eca4f9f105676','57c8a998c3664c842eea26705fe5344d51cd41792fd6742a140ab687fae61dee'),
('claudio.rodrigues@bertuolfertilizantes.com.br','claudio.rodrigues@bertuolfertilizantes.com.br','Claudio','Rodrigues','BERTUOL INDUSTRIA DE FERTILIZANTES LTDA','Coordenador de Tecnologia da Informação','Agro','66992274603','ae925ee89df3a547e6e3547f5d973fd04d202e913358207b65886e785a8191cf','a9baae35db4aff8e4738f62c9c9e5cff26550233dde4c5b5d46a9b72959ea07c'),
('lara.brainer@agu.gov.br','brainer.lara@gmail.com','Lara Brainer Magalhães','Torres de Oliveira','AGU','Coordenadora Geral','Serviços Públicos','21992014727','60991b1bb52ba8917954a78793e764fbe264124c7be14eb6a4070d3c06a4ff45','97700004c285d2ddbb0065dc08a225a3ffa143fdfb2b2f99e83bd99edb10ba02'),
('mjcosta@grupobig.com.br','mjullys@gmail.com','Meyb Jullys','Costa SAntos','Big Lar','Coordenador de TI','Comercio Varejista e Atacadista','62986117992','1c2fcd5c4c88613c6812cac031915e9d0fd59ef43361d82ce64329bcb14e3a14','d41ece87e632ed87f65992740652769b4316cafbba71169898bd64e39782eb04'),
('taciano.rossi.pj@varellapesados.com.br','tacianorossi@hotmail.com','Taciano','de Oliveira Rossi Arantes','Varella Scania','Coordenador de TI','Transportes e Logística','62984263157','ef9f0f68110297d471079f750049b6299fd0f1b3db7f29e46bc15b234cb9e2a7','5fd5697726c212e602b22c9334a98c097a2a58265121e241584cad1f2f89e676'),
('evelline.carvalho@redefrota.com.br','evelline.carvalho@redefrota.com.br','Evelline','Carvalho de Oliveira','rede frota','head de produto','Bancos e Serviços Financeiros','21968480075','a548084681a6bc4bf8dee16dcb80f95685270871c0b3795ca739c5f6ee77f16b','b42f8df1a6a4e51830d7b73200c735cecd2c0a4e71d0aa386c3e6d6c2474673f'),
('almir.dias@grupocopar.com.br','almirdiasfilho@gmail.com','Almir','Dias','DCCO','GERENTE DE TI','Serviços Outros','62991253364','1405f3b9e5622a8c538e28d69e16541ca912401fd02189998e159446cf473680','56d280acca1ef6cb04f338e92f9055b6c2caadf5ac144f968948d9c5d2e9e8db'),
('aldair.zanatta@novacasadistribuidora.com.br','giovanizanatta1@gmail.com','Aldair Giovani','Zanatta','Nova Casa Distribuidora SA','Diretor de TI','Comercio Varejista e Atacadista','47996178332','e20e57c08ef7bd01ecf9f1a627704a341a9e13d8b5df0af40dd7c63e15cf24d7','4a9e19d613fc1630dcb66835b2d2cc248fa79a4f699d695101fba29f48351f33'),
('hugo.maldonado@redemobconsorcio.com.br','suporte.maldonado@hotmail.com','Hugo','Maldonado','RedeMob Consórcio','Gerente de Tecnologia','Transportes e Logística','61991500111','a584fe2abaed69597f24b0677617a09242b517b7a66c4aaee923fa730e81bfea','e9902cf5086db30249f780a47ef0edd86f8a13b354b697a216d5af59db7130d0'),
('adriano.carvalho@fs.agr.br','adriano.carvalho@fs.agr.br','Adriano','Carvalho','FS FUELING SUSTAINABILITY','OPERATIONAL TECHNOLOGY COORDINATOR','Industria Química','65992294992','d805e147d5c713946b4099ea18168e18d3a1a54298926c67413f4d9937eb68c1','6d3a651561dee2f3e38c23d96974bfef167f1974404dd08567b6379ed8a1f888'),
('nickerson.queiros@agricolaalvorada.com.br','nqueiros@gmail.com','Nickerson','Ribeiro Queiros','Agrícola Alvorada','Coordenador SAP','Agro','62992301249','e0ba94c180167509a20caea2e8fcd59e6ba023d88a4b3802a7a58dfa24fd4105','58fab674ce670153e0a94e1b8169565dcbdd2fa331be3a1f38e328a75ce2399f'),
('uandersonoliveira@caesb.df.gov.br','uanderson.rodrigues@gmail.com','Uanderson','de Oliveira','Caesb','Gerente de Infraestrutura de TIC','Serviços Públicos','61984173603','06c5f2d1b801bb8a5a51025d136aeec6cd33ec829473bcf5498a3a6d459178ad','2caaa402ff50ff2d02a93da77ae1635a171dc61a9a019d6e549399a684a17462'),
('antonio.xavier@gavresorts.com.br','antonio.xavier@gavresorts.com.br','Antonio','Raimundo Silva Xavier','Gav Resorts','Gerente de Sistemas','Outros','62983257326','1053bea1c98e893f67d9b8095242c7f0cce5fc8b4d88b4b285300799ca77972b','4c5e4e2f9b5efa2b1cab0d81793a797594b8dd0ed3b8bc09ea8fe1c7a468cec9'),
('moacir@tbtmais.com.br','moacir@tbtmais.com.br','Moacir','Santos','Papelaria Tributária','Gerente de TI','Outros','62992362505','67582bf424fa9762958552d864afe660317c1a4c5668c83b1016867531090ed7','63eebd27d3513d926eda9a2954dc3c2335e8080d4be1954d6751346c0b725669'),
('fernando@escolainteramerica.com.br','fernando@escolainteramerica.com.br','Fernando','Rodrigues Ramos','Escola Interamérica','Gerente TI','Educação','62981702591','ec3407e730c1a61d3a88423f2ce4934ff88fd536c2197c89dceda2775154e745','ff83a32453c5e446b210c43015e19fb801073bc8e126ad0a00023848b54791ef'),
('cleyton.pereira@navesa.com.br','cleyton_cpd@hotmail.com','Cleyton','Pereira da Silva','Grupo Navesa','Gerente TI','Comercio Varejista e Atacadista','62984753899','b660f2eb066584a3f09f58dbf8dc225565b4e559c76bf31a089d8952820bfed5','1243325e2122ee6092c5b59a9286ecea0a9485ac2dbe3edfc0ad14f4b4751bd4'),
('geraldo.barcellos@adasa.df.gov.br','geraldo.barcellos@adasa.df.gov.br','Geraldo Alves','Barcellos','Adasa','Chefe do Serviço de Tecnologia da Informação e Comunicação','Serviços Públicos','61996189931','5d7b393239ccb31c0583fe0b6c6cbf0d2e02f1914b32750c94496af7be72bd92','e50a7032b7c616fcc3de73f86a33881ed1e470c96518107a7ffc16ece7fe6808')
on conflict (email) do update set
  nome = excluded.nome, sobrenome = excluded.sobrenome, empresa = excluded.empresa,
  cargo = excluded.cargo, industria = excluded.industria,
  telefone  = coalesce(nullif(excluded.telefone,''), public.ibm_consent.telefone),
  hash_cpf  = coalesce(excluded.hash_cpf,  public.ibm_consent.hash_cpf),
  hash_nasc = coalesce(excluded.hash_nasc, public.ibm_consent.hash_nasc);

-- Conferencia
select status, count(*) from public.ibm_consent group by status;
select count(*) filter (where hash_cpf is not null)  as com_cpf,
       count(*) filter (where hash_nasc is not null) as com_nascimento
from public.ibm_consent;
