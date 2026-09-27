// Shambleta — ponte de rewarded ads (SOM-IDLE Fase E, MONETIZAÇÃO §2.5).
//
// O client Godot (sources/ads/AdProvider.gd, provider "portal") procura
// `window.ShambletaAds` com dois métodos:
//
//   ShambletaAds.ad_ready(placement) -> bool
//       "há um rewarded disponível para este placement?" (4 placements:
//       "afkhoras", "chest", "reroll", "bosskey").
//   ShambletaAds.show_rewarded(placement, done_callback)
//       exibe o rewarded; chama done_callback(true) SE o anúncio foi assistido
//       até o fim, done_callback(false) se pulado/fechado antes. O Godot passa
//       um Callable como done_callback (JavaScriptBridge invoca de volta).
//       Este arquivo NÃO vê nem devolve token: a autorização é pedida ao
//       servidor antes (Network.RequestAdSlot) e o que volta para o jogo é o
//       nonce de uso único que o servidor mintou (`ad_slot`, TTL 300 s).
//       done_callback(false) = nada entregue = nada creditado.
//
// Decisão do dono (2026-09-18): CRAZYGAMES. Trocar o corpo das duas funções
// abaixo pelo SDK real quando a conta do portal existir; o jogo não muda.
// Seleção via env SHAMBLETA_AD_PROVIDER ("stub" = sem SDK, "portal" = usa esta
// ponte). Sem esta ponte carregada, o client cai para o stub — e em nenhum dos
// dois caminhos o client fabrica credential: sem slot mintado pelo servidor o
// crédito é recusado (`bad_token`), os caps por placement (1 baú/dia,
// 2 chaves/dia, 3 rerolls/dia, 12 horas de offline/dia) contam views **mais** as
// reservas ainda não gastas, e a mintagem só existe se `SHAMBLETA_AD_STUB=1`
// estiver no servidor (C2, auditoria 2026-09-24 — default fechado, fora do
// compose de produção). O que a ponte ainda não prova é exibição: isso é SSV.
//
// -----------------------------------------------------------------------------
// TEST MODE — DESLIGADO POR DEFAULT desde 2026-09-27 (SOM-W5/A).
//
// Antes este arquivo tinha `TEST_MODE = true` fixo: a ponte respondia
// "anúncio assistido" para QUALQUER página que a carregasse, sem exibir nada.
// Com o `SHAMBLETA_AD_STUB=1` do servidor ligado, isso virava crédito real por
// clique falso — a mentira ponta-a-ponta. Agora:
//
//   * default: TEST_MODE = false. Sem SDK do portal carregado, ad_ready()
//     devolve false (nada há para assistir) e show_rewarded() cai no provider
//     real, que ainda não existe e devolve done(false). Client → stub local,
//     servidor default-fechado → nenhum crédito. Caminho seguro.
//   * operador/QA: abrir o jogo com `?adstest=1` na URL habilita o simulador
//     (2 s, sempre "concluído") para validar o fluxo UI→nonce→crédito num
//     ambiente onde o stub do servidor ESTEJA ligado de propósito (staging).
//     A flag é só client-side: não autoriza nada sozinha — o crédito continua
//     dependendo do slot mintado pelo servidor.
//
// Uso (operador): incluir o SDK do portal + este arquivo no index servido,
// antes do boot do Godot (o serviço `web` já copia este arquivo e o nginx o
// serve com no-cache). Ex. CrazyGames v3:
//   <script src="https://sdk.crazygames.com/crazygames-sdk-v3.js"></script>
//   <script src="/ads_bridge.js"></script>
(function () {
  "use strict";

  // Flag explícita de URL (?adstest=1) — a única forma de ligar o simulador.
  var TEST_MODE = /[?&]adstest=1(?:&|$)/.test(window.location.search);
  var TEST_SECONDS = 2;

  function crazyReal_show(placement, done) {
    // Exemplo CrazyGames v3 (descomentar com o SDK carregado):
    // window.CrazyGames.SDK.ad.requestAd("rewarded", {
    //   adStarted: function () {},
    //   adFinished: function () { done(true); },
    //   adError: function () { done(false); },
    // });
    // Sem SDK real ainda: nada foi exibido => done(false) => nada creditado.
    done(false);
  }

  function crazyReal_ready(placement) {
    // Portal real: return window.CrazyGames ... disponibilidade;
    return false;
  }

  window.ShambletaAds = {
    ad_ready: function (placement) {
      if (TEST_MODE) { return true; }
      return crazyReal_ready(placement);
    },
    show_rewarded: function (placement, done) {
      if (TEST_MODE) {
        setTimeout(function () { done(true); }, TEST_SECONDS * 1000);
        return;
      }
      crazyReal_show(placement, done);
    },
  };
})();
