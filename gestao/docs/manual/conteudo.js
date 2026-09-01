// Conteudo do Manual do Sistema de Gestao — CIO Cerrado
// Traduzido, para publico nao-tecnico (socios e analista), a partir da
// documentacao funcional conferida contra o codigo em docs/ (2026-09-01).

const M = require("./gerar_manual.js");
const {
  h1, h2, h3, p, pRich, bold, reg, ital, bullet, bulletRich, callout, espaco,
  quebraDePagina, tabelaDuasColunas,
} = M;

const conteudo = [];
const push = (...els) => conteudo.push(...els);

// =======================================================================
// CAPA
// =======================================================================
push(
  new M.Paragraph({ spacing: { before: 2400, after: 120 }, alignment: M.AlignmentType.CENTER,
    children: [new M.TextRun({ text: "CIO CERRADO", bold: true, size: 44, color: M.VERDE, font: M.FONTE_TITULO })] }),
  new M.Paragraph({ spacing: { after: 600 }, alignment: M.AlignmentType.CENTER,
    children: [new M.TextRun({ text: "Manual do Sistema de Gestão de Eventos", size: 30, color: M.CINZA_TEXTO, font: M.FONTE_TITULO })] }),
  new M.Paragraph({ spacing: { after: 3200 }, alignment: M.AlignmentType.CENTER,
    children: [new M.TextRun({ text: "Guia para a diretoria e para a equipe que opera o sistema no dia a dia", size: 22, italics: true, color: M.CINZA_SUAVE, font: M.FONTE_CORPO })] }),
  new M.Paragraph({ alignment: M.AlignmentType.CENTER, spacing: { after: 80 },
    children: [new M.TextRun({ text: "Setembro de 2026", size: 20, color: M.CINZA_SUAVE, font: M.FONTE_CORPO })] }),
  new M.Paragraph({ alignment: M.AlignmentType.CENTER,
    children: [new M.TextRun({ text: "Base publicada em ciocerrado.netlify.app/gestao/", size: 18, color: M.CINZA_SUAVE, font: M.FONTE_CORPO })] }),
  quebraDePagina(),
);

// =======================================================================
// SUMARIO
// =======================================================================
push(
  h1("Sumário"),
  new M.TableOfContents("Sumário", { hyperlink: true, headingStyleRange: "1-3" }),
  quebraDePagina(),
);

// =======================================================================
// 1. INTRODUCAO
// =======================================================================
push(h1("1. O que é este sistema"));

push(p(
  "Até pouco tempo atrás, organizar um evento do CIO Cerrado — desde a inscrição do " +
  "primeiro CIO até o crachá do último convidado — dependia de uma sequência de " +
  "planilhas, scripts avulsos e conferências manuais. Cada etapa vivia num lugar " +
  "diferente, e juntar tudo era trabalho de gente, sempre sob risco de um dado " +
  "desatualizado em algum canto."
));
push(p(
  "O sistema de gestão substitui essa colcha de retalhos por um só lugar, com regra " +
  "clara em cada etapa. Ele não substitui as ferramentas que já funcionam bem — " +
  "Sympla para inscrição, Autentique para contrato — ele conecta o que vem delas e " +
  "organiza tudo o que acontece depois."
));

push(h2("1.1 O caminho de um evento, do início ao fim"));
push(p("Um evento grande do CIO Cerrado passa por seis etapas, nesta ordem:"));
push(
  bullet("Inscrição — o CIO ou o patrocinador se inscreve pelo Sympla."),
  bullet("Contrato — depois de aprovado, a organização envia o contrato pelo Autentique."),
  bullet("Hospedagem — o CIO preenche seus dados de quarto, acompanhante e transfer."),
  bullet("Portal do patrocinador — a empresa patrocinadora organiza sua cota: quartos, mesa redonda, indicação de convidados, brindes."),
  bullet("Jantares — a organização escolhe, com apoio de inteligência artificial, quem senta à mesa de cada patrocinador."),
  bullet("Check-in — no dia do evento, a equipe registra a chegada de cada pessoa."),
);
push(p(
  "Jantares avulsos (fora do evento grande) seguem um caminho mais curto: não têm " +
  "hospedagem nem transfer, só a curadoria de convidados e o check-in no dia."
));
push(espaco());

push(h2("1.2 Quem usa o quê"));
push(p("O sistema tem quatro portas de entrada diferentes, uma para cada tipo de usuário:"));
push(tabelaDuasColunas({
  cab1: "Quem", cab2: "O que faz e onde",
  itens: [
    ["Organização (sócios e analista)", "Acesso total ao painel de gestão — aprova inscrição, acompanha pendência, cadastra patrocinador, cuida do financeiro. É o painel descrito no capítulo 2."],
    ["Equipe de apoio (staff do dia)", "Acesso operacional, mais restrito — principalmente check-in no dia do evento. Não altera cadastro, cota nem valor."],
    ["Patrocinador", "Gerencia a própria cota num portal só dele: quartos, mesa redonda, indicação de CIO, brinde, financeiro da cota. Uma empresa pode ter mais de uma pessoa com acesso."],
    ["CIO convidado", "Confirma seus próprios dados, informa acompanhante e filho, escolhe transfer — tudo numa área pensada para ser preenchida em poucos minutos, do celular."],
  ],
}));
push(espaco());
push(callout(
  "Regra que vale para o sistema inteiro",
  "Nenhum patrocinador vê dado de outro — nem por acaso, nem forçando a URL, nem em " +
  "relatório. Essa garantia foi auditada linha a linha e está descrita no capítulo 9. " +
  "É a regra mais importante de todo o sistema."
));
push(espaco());

push(h2("1.3 Como entrar no sistema"));
push(p(
  "Todo mundo entra da mesma forma: por um link enviado por e-mail (chamado de " +
  "\"link mágico\") ou, para quem prefere, criando uma senha na primeira vez. Não há " +
  "usuário e senha compartilhados — cada pessoa tem seu próprio acesso, vinculado ao " +
  "seu e-mail."
));

push(quebraDePagina());

// =======================================================================
// 2. O PAINEL DA ORGANIZACAO
// =======================================================================
push(h1("2. O painel da organização"));
push(p(
  "É a tela central do sistema — onde a analista passa a maior parte do tempo, e onde " +
  "os sócios podem conferir o andamento do evento a qualquer momento. Tem 17 assuntos " +
  "diferentes, organizados em abas, e todos giram em torno do evento selecionado no " +
  "topo da tela."
));
push(callout(
  "Um detalhe que vale saber",
  "Trocar o evento selecionado no topo troca o conteúdo de quase toda aba — é assim " +
  "que o mesmo sistema atende a um evento grande e a vários jantares avulsos ao " +
  "mesmo tempo, sem misturar os dados de um com o do outro."
));
push(espaco());

push(h2("2.1 Painel — o resumo do evento"));
push(p(
  "A primeira tela que aparece ao entrar. Mostra em números como o evento está: " +
  "quantos inscritos, quantos contratos assinados, quantos patrocinadores por cota. " +
  "É um retrato rápido — para conferir um dado com precisão, o caminho certo é a " +
  "lista ou a exportação da aba específica, não este resumo."
));

push(h2("2.2 Cadastro — a base de contatos"));
push(p(
  "Aqui vive o cadastro de todas as pessoas (os CIOs e executivos) que já passaram " +
  "pelo CIO Cerrado, em qualquer edição. Não é um cadastro por evento — é uma base " +
  "única, que cresce com o tempo e é reaproveitada sempre."
));
push(p("O cadastro chega de três formas:"));
push(
  bullet("Pela inscrição do Sympla, automaticamente ou por planilha exportada;"),
  bullet("Por importação de planilha própria, quando alguém prepara uma lista fora do Sympla;"),
  bullet("Por indicação de um patrocinador, que sugere um executivo pelo portal dele."),
);
push(p(
  "Um cuidado importante: todo nome, empresa, cargo e cidade que entra no cadastro é " +
  "automaticamente colocado em maiúscula e o estado é conferido contra a lista das " +
  "27 unidades da federação — isso vale tanto para quem entra pela integração quanto " +
  "para quem é digitado à mão, sem exceção. É o que garante que a base fique " +
  "arrumada, esteja ela vindo de onde vier."
));
push(p(
  "Quando duas linhas do cadastro claramente são a mesma pessoa (mesmo nome, mesma " +
  "empresa), o sistema oferece fundir os dois registros num só, preservando o " +
  "histórico. E quando uma planilha nova traz uma empresa diferente da que já estava " +
  "cadastrada para alguém, isso não é aplicado direto — vira uma sugestão, que fica " +
  "esperando a analista revisar e confirmar antes de valer."
));
push(espaco());

push(h2("2.3 Aprovações — quem pode entrar"));
push(p(
  "Toda inscrição chega como pendente. Antes da aprovação, a pessoa não gera " +
  "contrato, não ocupa quarto e não conta em nenhuma cota — é um portão que " +
  "protege o resto do sistema de gente que ainda não deveria estar dentro do fluxo."
));
push(p(
  "É também aqui que uma indicação de CIO feita por um patrocinador — que começa " +
  "como uma sugestão — é avaliada e, se aprovada, vira de fato um convite."
));

push(h2("2.4 Acompanhamento — quem está devendo o quê"));
push(p(
  "Esta é a aba que resolve o maior problema do processo antigo: saber, sem precisar " +
  "vasculhar planilha nenhuma, quem ainda não fez o quê — e por quanto tempo."
));
push(p("A tela mostra, para cada etapa (inscrição, contrato, hospedagem, fatura paga e outras):"));
push(
  bullet("quantas pessoas/empresas estão em dia, em atenção ou já atrasadas;"),
  bullet("há quanto tempo cada pendência está aberta;"),
  bullet("um prazo configurável por etapa, que decide quando algo vira \"atenção\" e quando vira \"atrasado\"."),
);
push(p(
  "Quando alguém precisa ser cobrado, a analista clica em \"Preparar cobrança\": o " +
  "sistema já monta o e-mail, mostra para quem vai, avisa se essa pessoa já foi " +
  "cobrada nos últimos dias — e só sai depois de um clique explícito em " +
  "\"Enviar agora\"."
));
push(callout(
  "Por que isso importa",
  "Não existe \"cobrar todos de uma vez\". A decisão de mandar cada cobrança é " +
  "sempre humana — o sistema prepara e organiza, quem aperta o botão é a pessoa " +
  "responsável. Essa regra vale para todo tipo de disparo em massa no sistema " +
  "inteiro, não só aqui.",
  M.DOURADO, "FBF3E3",
));
push(espaco());

push(h2("2.5 Financeiro"));
push(p(
  "Controla o valor da cota de cada patrocinador e a situação de pagamento, além das " +
  "faturas adicionais dos CIOs (acompanhante, filho, item extra). O sistema registra " +
  "e organiza; o disparo do lembrete de cobrança em si é feito pela aba Acompanhamento, " +
  "que é onde a decisão de mandar a mensagem acontece."
));

push(h2("2.6 Estrutura do evento"));
push(p(
  "É onde o evento é montado antes de tudo o mais fazer sentido: as datas e prazos " +
  "gerais do evento, as cotas de patrocínio disponíveis (Esmeralda, Diamante, " +
  "Platina, Ouro, Prata), o inventário de quartos do resort e as categorias de " +
  "acomodação. Mexer aqui afeta praticamente todas as outras abas — é a base de " +
  "tudo."
));

push(h2("2.7 Patrocinadores"));
push(p(
  "Cadastro das empresas patrocinadoras e de quem tem acesso ao portal de cada uma " +
  "— é aqui que se cria o acesso de um segundo (ou terceiro) usuário da mesma " +
  "empresa, não pelo próprio portal do patrocinador. Também é onde os quartos que a " +
  "cota dá direito são gerados de uma vez para todos os patrocinadores do evento."
));

push(h2("2.8 Quartos, Organização e Etiquetas"));
push(p("Três abas de logística, com propósitos diferentes que vale não confundir:"));
push(
  bulletRich([bold("Quartos — "), reg("alocação física de cada pessoa a um quarto real do resort.")]),
  bulletRich([bold("Organização — "), reg("hospedagem da própria equipe do CIO Cerrado, fora da cota de qualquer patrocinador.")]),
  bulletRich([bold("Etiquetas — "), reg("geração de crachá a partir da lista já consolidada de quem vai participar.")]),
);

push(h2("2.9 Sessões, Atividades, Prospecção, Pesquisa e Preços"));
push(p("Cinco abas de apoio à operação e à curadoria do evento grande:"));
push(
  bulletRich([bold("Sessões — "), reg("visão da organização sobre mesa redonda e jantar por patrocinador: quem confirmou, sugestões por afinidade comercial, lista de e-mail (mailing).")]),
  bulletRich([bold("Atividades — "), reg("controle de presença por atividade do dia (manhã, pós-almoço), com check-in próprio — inclusive por leitura de QR code pela câmera do celular.")]),
  bulletRich([bold("Prospecção — "), reg("ferramenta de curadoria para mesa redonda, com controle para não repetir sempre os mesmos convidados entre rodadas.")]),
  bulletRich([bold("Pesquisa de perfil — "), reg("respostas de um formulário de perfil, organizadas por área de investimento.")]),
  bulletRich([bold("Preços — "), reg("tabela de preço de cada item cobrável (acompanhante, criança, transfer, quarto extra) — é o que alimenta o valor mostrado ao CIO antes de ele confirmar qualquer coisa.")]),
);

push(h2("2.10 Equipe"));
push(p("Reúne três assuntos numa aba só:"));
push(
  bulletRich([bold("Gestão de acesso — "), reg("quem é organizador, quem é staff, e a quais eventos cada pessoa da equipe está associada.")]),
  bulletRich([bold("Fila de e-mail — "), reg("acompanhamento dos envios pendentes ou com erro.")]),
  bulletRich([bold("Integração com o app do evento — "), reg("geração das planilhas de usuários e de empresas no formato exato que o aplicativo do parceiro aceita.")]),
);
push(espaco());

push(h2("2.11 Uma divisão de acesso que vale entender"));
push(p(
  "A equipe de apoio (staff) enxerga as mesmas 17 abas que a analista e os sócios " +
  "veem — mas a maior parte das ações dentro delas é reservada só para quem tem " +
  "acesso de organização. Isso vale inclusive para simplesmente ver uma lista, não " +
  "só para alterar algo. Na prática: o staff do dia do evento consegue operar o " +
  "check-in muito bem, mas não deveria (e não consegue) mexer em cadastro, cota, " +
  "valor ou estrutura do evento."
));

push(quebraDePagina());

// =======================================================================
// 3. PORTAL DO PATROCINADOR
// =======================================================================
push(h1("3. O portal do patrocinador"));
push(p(
  "É a tela que a empresa patrocinadora usa para cuidar da própria cota — a \"cara\" " +
  "do evento para quem está pagando por ele. Uma empresa pode ter mais de uma pessoa " +
  "com acesso, todas vendo exatamente os mesmos dados da empresa, e nada de nenhuma " +
  "outra."
));
push(p("Sete assuntos, em abas:"));

push(h2("3.1 Quartos"));
push(p(
  "Mostra os quartos que a cota da empresa dá direito e permite preencher quem " +
  "ocupa cada um. Se a empresa quiser um quarto a mais do que a cota inclui, o " +
  "portal mostra a disponibilidade em tempo real e o valor exato — e só reserva " +
  "depois de uma confirmação explícita do custo, nunca como surpresa na fatura."
));

push(h2("3.2 Mesa redonda"));
push(p(
  "O número de vagas de convidado vem da cota contratada. O patrocinador pode " +
  "indicar convidados próprios; o restante é escolhido pela organização, por porte " +
  "da empresa e afinidade comercial. Se a cota for excedida, o sistema bloqueia — " +
  "não aceita e cobra sem avisar."
));

push(h2("3.3 Indicações"));
push(p(
  "Formulário simples para o patrocinador sugerir executivos que gostaria de ver " +
  "convidados. Cada indicação tem um status visível e acompanhável: aguardando " +
  "convite, convidado, inscrito, não seguiu, ou já estava na base."
));
push(callout(
  "Regra importante para quem atende o patrocinador",
  "Indicação não é convite. Ela entra numa fila de avaliação da organização e só " +
  "vira convite de verdade depois de aprovada — isso precisa ficar claro para não " +
  "criar expectativa equivocada do lado do cliente."
));
push(espaco());

push(h2("3.4 Brindes"));
push(p(
  "Um brinde por empresa, não por quarto. O patrocinador informa o que é, a " +
  "quantidade e para onde vai (fica no stand da empresa, ou é entregue no quarto de " +
  "cada convidado — essa segunda opção tem custo). Depois de confirmado o envio, dá " +
  "para informar transportadora e código de rastreio, e a organização acompanha até " +
  "a entrega."
));

push(h2("3.5 Convidados"));
push(p(
  "Lista de quem a empresa já tem de fato confirmado — só aparece quem está " +
  "aprovado e já assinou o contrato. Propositalmente, essa lista não mostra e-mail " +
  "nem telefone do convidado: o contato só é liberado depois que o patrocinador " +
  "efetivamente escolhe aquela pessoa para a mesa."
));

push(h2("3.6 Financeiro"));
push(p(
  "Mostra os valores adicionais gerados pela empresa (quarto extra, brinde entregue " +
  "no quarto), com o total discriminado item a item, vencimento e situação de " +
  "pagamento. Não é a fatura da cota em si — essa é tratada à parte, pela " +
  "organização."
));

push(h2("3.7 Manual"));
push(p(
  "Nome, local, datas do evento e os prazos que afetam o CIO indicado por aquela " +
  "empresa (prazo de contrato, de hospedagem, de cancelamento) — informativo, para " +
  "consulta."
));

push(quebraDePagina());

// =======================================================================
// 4. AREA DO CIO
// =======================================================================
push(h1("4. A área do CIO convidado"));
push(p(
  "É a área que o executivo convidado usa para confirmar seus dados e organizar a " +
  "própria estadia. Substitui a antiga ficha de check-in em PDF, que circulava por " +
  "e-mail, era preenchida à mão, devolvida e conferida uma a uma."
));
push(p(
  "O público desse formulário é detalhista e não aceita ambiguidade em nada que " +
  "envolva dinheiro ou compromisso — por isso, toda a área foi pensada para mostrar " +
  "clareza antes de pedir confirmação."
));

push(h2("4.1 Quem ainda não está inscrito"));
push(p(
  "Existe uma porta de autocadastro para quem chega sem convite prévio — preenche " +
  "nome e e-mail, e a inscrição entra como pendente, para a organização avaliar, " +
  "igual a qualquer outra."
));

push(h2("4.2 A trilha de três passos"));
push(p("Para quem já está inscrito, a tela mostra exatamente onde a pessoa está:"));
push(
  bullet("Inscrição — aprovada, em análise, ou não aprovada;"),
  bullet("Contrato — assinado, enviado (com prazo visível), ou ainda não enviado;"),
  bullet("Dados de hospedagem — só libera depois que as duas etapas anteriores estiverem completas ao mesmo tempo."),
);

push(h2("4.3 Acompanhante, filho e transfer"));
push(p(
  "O titular já vem incluído. O CIO pode adicionar acompanhante(s) e filho(s) no " +
  "mesmo formulário, com nome, CPF e — para criança — data de nascimento, que é o " +
  "dado que decide cobrança e regra de crachá. Para o transfer, cada pessoa do " +
  "quarto pode escolher sua própria origem (Goiânia ou Brasília), mesmo estando no " +
  "mesmo quarto."
));
push(callout(
  "O valor sempre aparece antes de confirmar",
  "A cada campo preenchido, o resumo financeiro na mesma tela é recalculado na " +
  "hora — o convidado nunca é surpreendido pelo valor só depois de já ter " +
  "confirmado tudo."
));
push(espaco());

push(h2("4.4 Fatura adicional"));
push(p(
  "Consolida tudo que o CIO deve além do que já está incluso — acompanhante, " +
  "filho, item extra — sempre discriminado, item a item, nunca como um valor único " +
  "sem explicação."
));

push(quebraDePagina());

// =======================================================================
// 5. CHECK-IN
// =======================================================================
push(h1("5. Check-in no dia do evento"));
push(p(
  "Tela pensada para operação sob pressão: fila na frente, staff em pé, muitas " +
  "vezes alguém que nunca usou nenhum sistema de gestão antes. Cada decisão de " +
  "design responde a uma pergunta só — a pessoa consegue usar sozinha, na primeira " +
  "vez, com pressa?"
));
push(p("O que a tela faz:"));
push(
  bullet("Localiza a pessoa por busca de nome (funciona com nome parcial e sem acento) ou por leitura de QR code pela câmera do celular;"),
  bullet("Registra a chegada com um clique;"),
  bullet("Mostra o que o staff precisa saber na hora: quarto, categoria de crachá."),
);
push(p(
  "Check-in duplicado da mesma pessoa não gera dois registros — o sistema avisa que " +
  "ela já entrou. E se algo for marcado por engano, existe um botão de \"Desfazer\" " +
  "em cada linha, disponível para qualquer pessoa da equipe."
));
push(p(
  "O check-in de um jantar avulso funciona da mesma forma, só que com a busca por " +
  "nome — o QR code hoje vale para o check-in do evento grande."
));

push(quebraDePagina());

// =======================================================================
// 6. JANTARES
// =======================================================================
push(h1("6. Jantares — a curadoria de convidados"));
push(p(
  "Cada jantar tem um patrocinador. A organização escolhe quem senta à mesa — e essa " +
  "escolha, mais do que a logística do jantar em si, é o trabalho central deste " +
  "módulo. Jantar não depende do evento grande: tem vida própria, com data, local e " +
  "capacidade cadastrados à parte, e não carrega rooming, transfer, acompanhante " +
  "nem mesa redonda."
));

push(h2("6.1 Como um convidado chega até a lista"));
push(p("Três caminhos, que podem se combinar:"));
push(
  bulletRich([bold("Busca no cadastro — "), reg("quando já se sabe quem chamar, busca livre com filtro sobre a base inteira de contatos.")]),
  bulletRich([bold("Sugestão por aderência (inteligência artificial) — "), reg("o sistema cruza o perfil comercial do patrocinador com a base de gestores e pontua quem tem mais afinidade — a analista revisa e escolhe entre os sugeridos.")]),
  bulletRich([bold("Convite avulso — "), reg("para quem não está na base: equipe própria, ou um convidado de última hora.")]),
);
push(p(
  "Cada convidado passa por um funil de status: sugerido, convidado, confirmado, " +
  "compareceu — ou recusado, se for o caso."
));

push(h2("6.2 Estatísticas — evitar repetir sempre os mesmos nomes"));
push(p(
  "Uma aba dedicada mostra, sem enrolação: quem é convidado sempre e nunca confirma " +
  "presença; quem confirmou e depois não apareceu; e quem é chamado com mais " +
  "frequência de todos — sempre deixando de fora a própria equipe do CIO Cerrado, " +
  "que naturalmente comparece aos eventos que organiza. É a ferramenta que evita " +
  "que a curadoria vire sempre a mesma lista de nomes."
));

push(h2("6.3 Sondagem"));
push(p(
  "Permite rodar a mesma análise de aderência antes mesmo de o jantar existir de " +
  "fato — útil para levar um número concreto (\"temos X empresas com bom encaixe\") " +
  "para uma conversa comercial, sem comprometer capacidade nem criar convite algum " +
  "ainda."
));

push(quebraDePagina());

// =======================================================================
// 7. PERGUNTAS FREQUENTES
// =======================================================================
push(h1("7. Perguntas frequentes"));

const perguntas = [
  ["O patrocinador consegue ver dados de outro patrocinador de propósito ou por engano?",
   "Não. Essa é a garantia mais auditada de todo o sistema — cada tela de patrocinador só devolve dado da própria empresa, checado no momento de cada consulta, não só escondido na tela."],
  ["Uma cobrança pode sair sem ninguém perceber, de forma automática?",
   "Não. Toda cobrança — de pendência, de fatura — é preparada pelo sistema, mas só sai depois de um clique explícito de confirmação de uma pessoa da equipe. Não existe \"disparar para todos\" em nenhum lugar."],
  ["O que acontece se alguém preencher só metade de um formulário e sair da página?",
   "O formulário guarda o que já foi salvo e mostra isso na próxima visita — mas o que foi digitado e ainda não salvo pode se perder se a sessão cair no meio do preenchimento. É um ponto de atenção conhecido, sem solução ainda."],
  ["Dá para saber quem alterou um dado e quando?",
   "Só de forma bem limitada hoje — a maior parte das alterações não fica registrada com histórico de \"quem mudou o quê\". É um ponto que pode evoluir, se for prioridade."],
  ["A equipe de apoio do dia do evento (staff) pode mexer em qualquer coisa do sistema?",
   "Não. Staff opera principalmente o check-in. Praticamente todo o resto — cadastro, cota, valor, estrutura do evento — é reservado só para quem tem acesso de organização."],
  ["O sistema envia e-mail automaticamente, sem checagem?",
   "Depende do caminho: os lembretes de cobrança sempre passam por confirmação humana antes de sair. Já o botão de reenviar a fila de e-mails do painel dispara de verdade assim que clicado, sem uma segunda confirmação — vale usar com atenção."],
  ["O QR code do crachá já funciona?",
   "Sim, para o check-in do evento grande — a câmera do celular lê o QR e registra a chegada. Para jantar avulso, ainda é por busca de nome."],
];

for (const [q, r] of perguntas) {
  push(h3(q));
  push(p(r));
}

push(quebraDePagina());

// =======================================================================
// 8. GLOSSARIO
// =======================================================================
push(h1("8. Glossário"));
push(tabelaDuasColunas({
  cab1: "Termo", cab2: "Significado",
  itens: [
    ["Cota", "O nível de patrocínio de uma empresa (Esmeralda, Diamante, Platina, Ouro, Prata) — define quantos quartos, quantas vagas de mesa e quantos participantes ela tem direito."],
    ["Gestor", "Nome usado no sistema para qualquer pessoa cadastrada na base de contatos — não é só quem tem cargo de gestão, é o termo genérico para \"pessoa no cadastro\"."],
    ["Participante", "Um gestor que se inscreveu e foi aprovado para um evento específico."],
    ["Rooming", "O preenchimento dos dados de hospedagem do CIO — quarto, acompanhante, filho, transfer."],
    ["Sessão", "Uma rodada de mesa redonda ou de jantar vinculada a um patrocinador, dentro do evento grande."],
    ["Ocupante", "Qualquer pessoa que fica num quarto — o próprio CIO, um acompanhante, um filho, ou alguém da equipe do patrocinador."],
    ["Indicação", "Sugestão de executivo feita por um patrocinador, que precisa ser aprovada pela organização antes de virar convite."],
    ["Aderência", "A pontuação que a inteligência artificial dá para o quanto o perfil de uma empresa combina com o que um patrocinador vende — usada na curadoria de mesa redonda e de jantar."],
  ],
}, 2400, 6950));

push(espaco(400));
push(new M.Paragraph({
  border: { top: { style: M.BorderStyle.SINGLE, size: 6, color: M.LINHA, space: 8 } },
  spacing: { before: 200 },
  children: [new M.TextRun({ text: "Este manual acompanha o sistema e deve ser atualizado junto com ele. A documentação técnica completa, com todas as regras conferidas contra o código, vive em docs/ no repositório do sistema.", italics: true, size: 18, color: M.CINZA_SUAVE, font: M.FONTE_CORPO })],
}));

module.exports = conteudo;
