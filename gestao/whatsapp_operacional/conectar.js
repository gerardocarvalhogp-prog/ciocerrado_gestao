// Primeira conexao do numero operacional — roda uma vez, na mao, com o
// aparelho do numero operacional em maos pra escanear o QR. Depois
// disso a sessao fica salva em config.sessaoDir e o daemon (index.js)
// reconecta sozinho, sem QR de novo — so volta a pedir QR se a sessao
// for deslogada no proprio aparelho.
//
// USO:  npm run conectar
import { conectar, definirPerfil } from "./baileys_grupo.js";
import { config, exigirConfigProducao } from "./config.js";
import { rpc } from "./supa.js";

if (config.modo !== "producao") {
  console.error(
    "WHATSAPP_MODO nao esta como 'producao' — conectar sessao de verdade em modo teste\n" +
    "nao faz sentido (o resto do daemon simula tudo justamente pra nao precisar disso).\n" +
    "Defina WHATSAPP_MODO=producao no .env pra rodar esta primeira conexao de verdade."
  );
  process.exit(1);
}

exigirConfigProducao();

console.log("Abrindo conexao — se aparecer QR abaixo, escaneie com o WhatsApp do numero operacional");
console.log("(Aparelho > Configurações > Aparelhos conectados > Conectar um aparelho).\n");

await conectar({
  aoPrecisarQR() {
    console.log("\n↑ QR acima. Expira em ~20s — se sumir antes de escanear, espere o próximo aparecer.\n");
  },

  async aoConectar(sock) {
    console.log("Conectado. Configurando nome/foto do perfil...");
    try {
      await definirPerfil(sock);
      console.log(`Perfil configurado como "${config.perfilNome}".`);
    } catch (e) {
      console.warn("Não consegui configurar nome/foto do perfil agora — dá pra ajustar direto pelo app:", e.message);
    }

    await rpc("whatsapp_log_registrar", {
      p_jantar_id: null,
      p_acao: "sessao_conectada",
      p_detalhe: { primeira_conexao: true, numero: sock.user?.id || null },
    }).catch((e) => console.warn("Log da primeira conexão não gravou (sessão já está ok mesmo assim):", e.message));

    console.log("\nPronto. A sessão está salva em:", config.sessaoDir);
    console.log("Pode rodar `npm start` agora — não vai pedir QR de novo.");
    process.exit(0);
  },

  aoCair(motivo) {
    console.log(`Conexão caiu antes de terminar: ${motivo}. Rode de novo.`);
  },
});
