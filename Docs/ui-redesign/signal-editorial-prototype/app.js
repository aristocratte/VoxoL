const appWindow = document.querySelector(".app-window");
const screens = [...document.querySelectorAll(".screen")];
const targetButtons = [...document.querySelectorAll("[data-target]")];
const toolbarButtons = [...document.querySelectorAll(".prototype-toolbar [data-target]")];
const navButtons = [...document.querySelectorAll(".nav-item")];
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
const params = new URLSearchParams(window.location.search);
const motionCapture = params.get("motion") === "1";

if (params.get("capture") === "1") {
  document.body.classList.add("is-capture");
}

function showScreen(name, options = {}) {
  const next = screens.find((screen) => screen.dataset.screen === name) ?? screens[0];
  const current = document.querySelector(".screen.is-active");

  if (current !== next && !options.initial) {
    next.classList.add("is-entering");
    requestAnimationFrame(() => {
      requestAnimationFrame(() => next.classList.remove("is-entering"));
    });
  }

  screens.forEach((screen) => {
    const active = screen === next;
    screen.classList.toggle("is-active", active);
    screen.setAttribute("aria-hidden", String(!active));
  });

  appWindow.dataset.current = next.dataset.screen;
  navButtons.forEach((button) => {
    const active = button.dataset.target === next.dataset.screen;
    button.classList.toggle("is-current", active);
    button.setAttribute("aria-current", active ? "page" : "false");
  });
  toolbarButtons.forEach((button) => {
    button.classList.toggle("is-current", button.dataset.target === next.dataset.screen);
  });

  if (!options.initial) {
    const nextParams = new URLSearchParams(window.location.search);
    nextParams.set("screen", next.dataset.screen);
    history.replaceState(null, "", `${window.location.pathname}?${nextParams.toString()}`);
  }

  drawAllDither();
}

targetButtons.forEach((button) => {
  button.addEventListener("click", () => showScreen(button.dataset.target));
});

function selectWithin(button) {
  button.parentElement.querySelectorAll("button").forEach((candidate) => {
    candidate.classList.toggle("is-selected", candidate === button);
  });
}

document.querySelectorAll(".segmented-control button").forEach((button) => {
  button.addEventListener("click", () => selectWithin(button));
});

document.querySelectorAll(".library-tabs button").forEach((button) => {
  button.addEventListener("click", () => selectWithin(button));
});

document.querySelectorAll(".settings-nav button").forEach((button) => {
  button.addEventListener("click", () => selectWithin(button));
});

const toast = document.querySelector(".toast");
let toastTimer;

function showToast(message) {
  toast.textContent = message;
  toast.classList.add("is-visible");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove("is-visible"), 1600);
}

document.querySelector(".copy-button").addEventListener("click", () => {
  showToast("Copié dans le presse papiers");
});

document.querySelectorAll(".settings-row button").forEach((button) => {
  button.addEventListener("click", () => showToast("Ce réglage sera relié à la build SwiftUI"));
});

const languageButton = document.querySelector(".language-button");
languageButton.addEventListener("click", () => {
  const english = languageButton.dataset.language === "en";
  languageButton.dataset.language = english ? "fr" : "en";
  languageButton.innerHTML = english ? "Français <span>⌄</span>" : "English <span>⌄</span>";
});

const voiceTrigger = document.querySelector(".voice-trigger");
voiceTrigger.addEventListener("click", () => {
  const listening = voiceTrigger.getAttribute("aria-pressed") !== "true";
  voiceTrigger.setAttribute("aria-pressed", String(listening));
  voiceTrigger.classList.toggle("is-listening", listening);
  voiceTrigger.querySelector(".voice-trigger__label").textContent = listening
    ? "Relâcher pour insérer"
    : "Maintenir pour dicter";
  const canvas = document.querySelector(".voice-hero .dither-canvas");
  canvas.dataset.mode = listening ? "voice" : "idle";
  canvas.dataset.active = listening ? "true" : "false";
  drawAllDither();
});

document.querySelectorAll("[data-meeting-tab]").forEach((button) => {
  button.addEventListener("click", () => {
    document.querySelectorAll("[data-meeting-tab]").forEach((tab) => {
      tab.setAttribute("aria-selected", String(tab === button));
    });
    document.querySelectorAll("[data-meeting-panel]").forEach((panel) => {
      panel.hidden = panel.dataset.meetingPanel !== button.dataset.meetingTab;
    });
  });
});

function iconPath(name) {
  return `assets/icons/${name}`;
}

const preflightExamples = [
  {
    raw: "Euh, envoie-le mardi — non, mercredi matin.",
    ready: "Envoie-le mercredi matin.",
    operation: "Correction comprise",
  },
  {
    raw: "Bonjour Léa merci pour ton retour on valide vendredi.",
    ready: "Bonjour Léa,<br><br>Merci pour ton retour. On valide vendredi.",
    operation: "Structure retrouvée",
  },
  {
    raw: "Le budget est de quatre mille cinq cents euros.",
    ready: "Le budget est de 4 500 €.",
    operation: "Faits protégés",
  },
];

const grantedPermissions = new Set(["microphone"]);
let preflightDemoIndex = 0;
let firstFlightComplete = false;
let preflightDemoInterval;
let preflightSwapTimer;
let preflightFlightTimer;
let preflightTransitionTimer;
let activePreflightViewTransition;

function introScene() {
  const example = preflightExamples[preflightDemoIndex];
  return `
    <div class="preflight-scene intro-scene">
      <div class="scene-bar">
        <span class="scene-live"><i></i> Démonstration locale</span>
        <span class="demo-count">0${preflightDemoIndex + 1} / 03</span>
      </div>
      <div class="transform-demo">
        <article class="demo-card demo-card--raw morph-panel-a">
          <span>Entendu</span>
          <p data-demo-raw>${example.raw}</p>
        </article>
        <div class="demo-resolver" aria-hidden="true">
          <span class="demo-resolver__mark morph-mark"><img src="assets/mark-threshold.svg" alt="" /></span>
          <small data-demo-operation>${example.operation}</small>
        </div>
        <article class="demo-card demo-card--ready morph-panel-b">
          <span>Prêt à insérer</span>
          <p data-demo-ready>${example.ready}</p>
        </article>
      </div>
      <div class="demo-footer">
        <div class="demo-proof">
          <span><img src="${iconPath("lock-key.svg")}" alt="" /> Sur ce Mac</span>
          <span><img src="${iconPath("text-aa.svg")}" alt="" /> Sens préservé</span>
          <span><img src="${iconPath("arrow-right.svg")}" alt="" /> Dans l’app active</span>
        </div>
        <div class="demo-selector" aria-label="Choisir un exemple">
          ${preflightExamples.map((_, index) => `<button type="button" data-demo-index="${index}" class="${index === preflightDemoIndex ? "is-selected" : ""}" aria-label="Exemple ${index + 1}"><span></span></button>`).join("")}
        </div>
      </div>
    </div>`;
}

function permissionRow(icon, title, detail, key) {
  const allowed = grantedPermissions.has(key);
  const action = allowed
    ? `<span class="is-allowed"><img src="${iconPath("check.svg")}" alt="" /> Autorisé</span>`
    : `<button type="button" data-grant="${key}">Autoriser</button>`;
  return `<div class="permission-row" data-permission-row="${key}"><span class="permission-row__icon"><img src="${iconPath(icon)}" alt="" /></span><span><strong>${title}</strong><small>${detail}</small></span>${action}</div>`;
}

function permissionsScene() {
  const count = grantedPermissions.size;
  return `
    <div class="preflight-scene permissions-scene ${count === 3 ? "is-complete" : ""}">
      <div class="scene-bar">
        <span>Accès macOS</span>
        <span class="permission-count">${count} / 3 autorisés</span>
      </div>
      <div class="access-layout">
        <div class="access-orbit morph-panel-a" aria-hidden="true">
          <span class="access-orbit__ring"></span>
          <span class="access-core morph-mark"><img src="assets/mark-threshold.svg" alt="" /></span>
          <span class="access-node access-node--microphone ${grantedPermissions.has("microphone") ? "is-on" : ""}" data-permission-node="microphone"><img src="${iconPath("microphone.svg")}" alt="" /></span>
          <span class="access-node access-node--accessibility ${grantedPermissions.has("accessibility") ? "is-on" : ""}" data-permission-node="accessibility"><img src="${iconPath("text-aa.svg")}" alt="" /></span>
          <span class="access-node access-node--shortcut ${grantedPermissions.has("shortcut") ? "is-on" : ""}" data-permission-node="shortcut"><img src="${iconPath("command.svg")}" alt="" /></span>
          <small>Une bulle système à la fois</small>
        </div>
        <div class="permission-panel morph-panel-b">
          <h2>Trois accès. Rien de plus.</h2>
          <div class="permission-list">
            ${permissionRow("microphone.svg", "Microphone", "Entendre ta voix", "microphone")}
            ${permissionRow("text-aa.svg", "Accessibilité", "Insérer le résultat", "accessibility")}
            ${permissionRow("command.svg", "Entrée", "Détecter ⌥ Espace", "shortcut")}
          </div>
        </div>
      </div>
      <p class="scene-caption"><img src="${iconPath("shield-check.svg")}" alt="" /> Après chaque action, VoxoL relit le véritable état de macOS.</p>
    </div>`;
}

function enginesScene() {
  return `
    <div class="preflight-scene engines-scene">
      <div class="scene-bar">
        <span>Pipeline local</span>
        <span class="engine-status"><i></i> 2 moteurs vérifiés</span>
      </div>
      <div class="engine-flow">
        <article class="engine-card engine-card--asr morph-panel-a">
          <span class="engine-card__icon"><img src="${iconPath("waveform.svg")}" alt="" /></span>
          <div><small>Voix → mots</small><h2>Parakeet</h2><p>Reconnaît ta phrase sur ce Mac.</p></div>
          <span class="engine-check"><img src="${iconPath("check.svg")}" alt="" /> 642 Mo</span>
        </article>
        <div class="engine-bridge" aria-hidden="true">
          <span class="engine-orchestrator morph-mark"><img src="assets/mark-threshold.svg" alt="" /></span>
          <i></i><i></i><i></i><i></i>
        </div>
        <article class="engine-card engine-card--text morph-panel-b">
          <span class="engine-card__icon"><img src="${iconPath("text-aa.svg")}" alt="" /></span>
          <div><small>Mots → texte prêt</small><h2>Qwen</h2><p>Nettoie sans réinventer le sens.</p></div>
          <span class="engine-check"><img src="${iconPath("check.svg")}" alt="" /> 645 Mo</span>
        </article>
      </div>
      <div class="pipeline-example">
        <span>« euh, jeudi à neuf heures »</span>
        <img src="${iconPath("arrow-right.svg")}" alt="" />
        <strong>« Jeudi à 9 h. »</strong>
      </div>
      <p class="scene-caption"><img src="${iconPath("lock-key.svg")}" alt="" /> Les états suivent le téléchargement réel et la vérification des fichiers.</p>
    </div>`;
}

function firstFlightScene() {
  const completeClass = firstFlightComplete ? "is-complete" : "is-idle";
  return `
    <div class="preflight-scene flight-scene ${completeClass}" data-flight-state="${firstFlightComplete ? "complete" : "idle"}">
      <div class="scene-bar">
        <span>Première interaction</span>
        <span>Démonstration guidée · 0 audio enregistré</span>
      </div>
      <div class="flight-workbench">
        <div class="flight-prompt morph-panel-a">
          <span class="flight-prompt__label" data-flight-status>${firstFlightComplete ? "Prêt à insérer" : "Phrase de démonstration"}</span>
          <p data-flight-text>${firstFlightComplete ? "Reporte le point à jeudi, 9 h." : "Euh, reporte le point mardi — non, jeudi à neuf heures."}</p>
          <small data-flight-note>${firstFlightComplete ? "Correction comprise · sens préservé" : "Maintiens le bouton, puis relâche."}</small>
        </div>
        <button class="flight-hold morph-panel-b" type="button" aria-pressed="false">
          <span class="flight-hold__icons morph-mark" aria-hidden="true">
            <img class="flight-icon flight-icon--microphone" src="${iconPath("microphone.svg")}" alt="" />
            <img class="flight-icon flight-icon--check" src="${iconPath("check.svg")}" alt="" />
          </span>
          <span class="flight-hold__label">${firstFlightComplete ? "Rejouer la démo" : "Maintenir pour essayer"}</span>
          <kbd>⌥ Espace</kbd>
        </button>
      </div>
      <div class="flight-meter" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i></div>
    </div>`;
}

function readyScene() {
  return `
    <div class="preflight-scene ready-scene">
      <div class="ready-reveal morph-panel-a">
        <span class="ready-mark morph-mark"><img src="assets/mark-threshold.svg" alt="" /></span>
        <div><p class="eyebrow">Configuration vérifiée</p><h2>VoxoL est prêt.</h2><p>Ta voix peut maintenant devenir du texte dans n’importe quelle app.</p></div>
      </div>
      <div class="ready-proof-grid">
        <article><span><img src="${iconPath("command.svg")}" alt="" /></span><div><strong>⌥ Espace</strong><small>Maintenir pour parler</small></div><img src="${iconPath("check.svg")}" alt="" /></article>
        <article><span><img src="${iconPath("lock-key.svg")}" alt="" /></span><div><strong>100 % local</strong><small>Audio et texte restent ici</small></div><img src="${iconPath("check.svg")}" alt="" /></article>
        <article><span><img src="${iconPath("books.svg")}" alt="" /></span><div><strong>Sous ton contrôle</strong><small>Historique désactivé par défaut</small></div><img src="${iconPath("check.svg")}" alt="" /></article>
      </div>
    </div>`;
}

const preflightSteps = [
  {
    eyebrow: "01 · Ce qu’on a construit",
    title: "Ta voix devient du texte, ici.",
    summary: "VoxoL entend, protège le sens et insère un texte prêt à envoyer.",
    assurance: "Aucun compte. Aucun détour par le cloud.",
    label: "La transformation",
    nextLabel: "Découvrir les accès",
    scene: "intro",
    mode: "preflight-intro",
    content: introScene,
  },
  {
    eyebrow: "02 · Partout sur macOS",
    title: "Trois accès. Rien de plus.",
    summary: "Chaque permission correspond à une action visible que tu déclenches toi-même.",
    assurance: "Modifiables à tout moment dans Réglages Système.",
    label: "Les accès",
    nextLabel: "Voir les moteurs",
    scene: "permissions",
    mode: "preflight-access",
    content: permissionsScene,
  },
  {
    eyebrow: "03 · Sous le capot",
    title: "Deux moteurs. Une seule sensation.",
    summary: "Parakeet reconnaît ta voix. Qwen prépare le texte. Le tout reste sur ce Mac.",
    assurance: "Environ 1,3 Go, téléchargé et vérifié une seule fois.",
    label: "Les moteurs",
    nextLabel: "Essayer l’interaction",
    scene: "engines",
    mode: "preflight-engines",
    content: enginesScene,
  },
  {
    eyebrow: "04 · À toi d’essayer",
    title: "Maintiens. Parle. Relâche.",
    summary: "Sens le geste avant ta première vraie dictée.",
    assurance: "Cette démonstration guidée n’enregistre aucun audio.",
    label: "Le premier geste",
    nextLabel: "Finaliser",
    scene: "flight",
    mode: firstFlightComplete ? "preflight-ready" : "preflight-voice",
    content: firstFlightScene,
  },
  {
    eyebrow: "05 · Prêt sur ce Mac",
    title: "Tout est là. À toi de parler.",
    summary: "Le raccourci, les moteurs et les accès ont été vérifiés.",
    assurance: "L’historique reste désactivé tant que tu ne l’actives pas.",
    label: "Prêt",
    nextLabel: "Ouvrir VoxoL",
    scene: "ready",
    mode: "preflight-ready",
    content: readyScene,
  },
];

let preflightIndex = Math.min(4, Math.max(0, Number(params.get("step") ?? 0)));
const preflightMain = document.querySelector(".preflight-main");
const preflightVisual = document.querySelector(".preflight-visual");
const preflightCanvas = preflightVisual.querySelector(".dither-canvas");
const preflightCard = document.querySelector(".preflight-card");
const preflightTitle = document.querySelector(".preflight-title");
const preflightSummary = document.querySelector(".preflight-summary");
const preflightEyebrow = document.querySelector(".preflight-eyebrow");
const preflightAssurance = document.querySelector(".preflight-assurance span");
const preflightProgress = document.querySelector(".preflight-progress");
const preflightStepLabel = document.querySelector(".preflight-step-label");
const preflightBack = document.querySelector(".preflight-back");
const preflightNext = document.querySelector(".preflight-next");

const preflightProgressCursor = document.createElement("span");
preflightProgressCursor.className = "preflight-progress__cursor";
preflightProgressCursor.setAttribute("aria-hidden", "true");
preflightProgress.append(preflightProgressCursor);

preflightSteps.forEach((_, index) => {
  const indicator = document.createElement("span");
  indicator.className = "preflight-progress__segment";
  indicator.setAttribute("aria-hidden", "true");
  preflightProgress.append(indicator);
});

function clearPreflightSceneTimers() {
  clearInterval(preflightDemoInterval);
  clearTimeout(preflightSwapTimer);
  clearTimeout(preflightFlightTimer);
}

function setDemoExample(index, animate = true) {
  preflightDemoIndex = (index + preflightExamples.length) % preflightExamples.length;
  const scene = preflightCard.querySelector(".intro-scene");
  if (!scene) return;
  const example = preflightExamples[preflightDemoIndex];
  const update = () => {
    scene.querySelector("[data-demo-raw]").textContent = example.raw;
    scene.querySelector("[data-demo-ready]").innerHTML = example.ready;
    scene.querySelector("[data-demo-operation]").textContent = example.operation;
    scene.querySelector(".demo-count").textContent = `0${preflightDemoIndex + 1} / 03`;
    scene.querySelectorAll("[data-demo-index]").forEach((button) => {
      button.classList.toggle("is-selected", Number(button.dataset.demoIndex) === preflightDemoIndex);
    });
    scene.classList.remove("is-swapping");
  };
  if (animate && !reducedMotion.matches) {
    scene.classList.add("is-swapping");
    clearTimeout(preflightSwapTimer);
    preflightSwapTimer = setTimeout(update, 160);
  } else {
    update();
  }
}

function bindIntroScene() {
  preflightCard.querySelectorAll("[data-demo-index]").forEach((button) => {
    button.addEventListener("click", () => setDemoExample(Number(button.dataset.demoIndex)));
  });
  if (!reducedMotion.matches && (!document.body.classList.contains("is-capture") || motionCapture)) {
    preflightDemoInterval = setInterval(() => setDemoExample(preflightDemoIndex + 1), 4200);
  }
}

function bindGrantButtons() {
  preflightCard.querySelectorAll("[data-grant]").forEach((button) => {
    button.addEventListener("click", () => {
      const key = button.dataset.grant;
      grantedPermissions.add(key);
      button.outerHTML = `<span class="is-allowed"><img src="${iconPath("check.svg")}" alt="" /> Autorisé</span>`;
      preflightCard.querySelector(`[data-permission-node="${key}"]`)?.classList.add("is-on");
      const count = grantedPermissions.size;
      preflightCard.querySelector(".permission-count").textContent = `${count} / 3 autorisés`;
      preflightCard.querySelector(".permissions-scene").classList.toggle("is-complete", count === 3);
    });
  });
}

function bindFirstFlightScene() {
  const scene = preflightCard.querySelector(".flight-scene");
  const trigger = scene?.querySelector(".flight-hold");
  if (!scene || !trigger) return;

  const status = scene.querySelector("[data-flight-status]");
  const text = scene.querySelector("[data-flight-text]");
  const note = scene.querySelector("[data-flight-note]");
  const label = scene.querySelector(".flight-hold__label");
  let listening = false;

  const start = () => {
    if (listening) return;
    clearTimeout(preflightFlightTimer);
    listening = true;
    scene.dataset.flightState = "listening";
    trigger.setAttribute("aria-pressed", "true");
    status.textContent = "VoxoL écoute…";
    text.textContent = "Euh, reporte le point mardi — non, jeudi à neuf heures.";
    note.textContent = "Relâche quand tu as terminé.";
    label.textContent = "Relâcher pour préparer";
    preflightCanvas.dataset.mode = "preflight-voice";
    drawAllDither();
  };

  const finish = () => {
    if (!listening) return;
    listening = false;
    scene.dataset.flightState = "processing";
    trigger.setAttribute("aria-pressed", "false");
    status.textContent = "VoxoL prépare…";
    note.textContent = "Le sens et les faits sont vérifiés.";
    label.textContent = "Préparation locale";
    preflightCanvas.dataset.mode = "process";
    drawAllDither();
    preflightFlightTimer = setTimeout(() => {
      firstFlightComplete = true;
      scene.dataset.flightState = "complete";
      scene.classList.add("is-complete");
      status.textContent = "Prêt à insérer";
      text.textContent = "Reporte le point à jeudi, 9 h.";
      note.textContent = "Correction comprise · sens préservé";
      label.textContent = "Rejouer la démo";
      preflightCanvas.dataset.mode = "preflight-ready";
      preflightNext.disabled = false;
      drawAllDither();
    }, reducedMotion.matches ? 40 : 720);
  };

  trigger.addEventListener("pointerdown", (event) => {
    event.preventDefault();
    trigger.setPointerCapture?.(event.pointerId);
    start();
  });
  trigger.addEventListener("pointerup", finish);
  trigger.addEventListener("pointercancel", finish);
  trigger.addEventListener("keydown", (event) => {
    if ((event.key === " " || event.key === "Enter") && !event.repeat) {
      event.preventDefault();
      start();
    }
  });
  trigger.addEventListener("keyup", (event) => {
    if (event.key === " " || event.key === "Enter") {
      event.preventDefault();
      finish();
    }
  });
}

function bindPreflightScene() {
  if (preflightIndex === 0) bindIntroScene();
  if (preflightIndex === 1) bindGrantButtons();
  if (preflightIndex === 3) bindFirstFlightScene();
}

function updatePreflight(index) {
  preflightIndex = Math.min(4, Math.max(0, index));
  const step = preflightSteps[preflightIndex];
  clearPreflightSceneTimers();
  preflightEyebrow.textContent = step.eyebrow;
  preflightTitle.textContent = step.title;
  preflightSummary.textContent = step.summary;
  preflightAssurance.textContent = step.assurance;
  preflightStepLabel.textContent = step.label;
  preflightCard.innerHTML = step.content();
  preflightMain.dataset.step = String(preflightIndex);
  preflightVisual.dataset.scene = step.scene;
  preflightCanvas.dataset.mode = preflightIndex === 3 && firstFlightComplete ? "preflight-ready" : step.mode;
  preflightProgress.style.setProperty("--preflight-step", String(preflightIndex));
  preflightProgress.querySelectorAll(".preflight-progress__segment").forEach((indicator, stepIndex) => {
    indicator.classList.toggle("is-current", stepIndex === preflightIndex);
    indicator.classList.toggle("is-complete", stepIndex < preflightIndex);
  });
  preflightBack.disabled = preflightIndex === 0;
  preflightNext.disabled = preflightIndex === 3 && !firstFlightComplete;
  preflightNext.innerHTML = `${step.nextLabel} <img src="${iconPath("arrow-right.svg")}" alt="" />`;
  bindPreflightScene();
  const nextParams = new URLSearchParams(window.location.search);
  nextParams.set("screen", "preflight");
  nextParams.set("step", String(preflightIndex));
  history.replaceState(null, "", `${window.location.pathname}?${nextParams.toString()}`);
  drawAllDither();
}

function playPreflightEntry() {
  preflightMain.classList.add("is-entering");
  requestAnimationFrame(() => {
    requestAnimationFrame(() => preflightMain.classList.remove("is-entering"));
  });
}

function renderPreflight(index, animate = false) {
  const nextIndex = Math.min(4, Math.max(0, index));
  const direction = nextIndex < preflightIndex ? "backward" : "forward";
  preflightMain.dataset.direction = direction;
  clearTimeout(preflightTransitionTimer);

  if (animate && !reducedMotion.matches && typeof document.startViewTransition === "function") {
    activePreflightViewTransition?.skipTransition();
    document.documentElement.dataset.preflightDirection = direction;
    preflightMain.classList.remove("is-entering", "is-leaving");
    preflightMain.classList.add("is-morphing");

    const transition = document.startViewTransition(() => updatePreflight(nextIndex));
    activePreflightViewTransition = transition;
    transition.finished.finally(() => {
      if (activePreflightViewTransition !== transition) return;
      activePreflightViewTransition = null;
      preflightMain.classList.remove("is-morphing");
      delete document.documentElement.dataset.preflightDirection;
    });
    return;
  }

  if (animate && !reducedMotion.matches) {
    preflightMain.classList.add("is-leaving");
    preflightTransitionTimer = setTimeout(() => {
      updatePreflight(nextIndex);
      preflightMain.classList.remove("is-leaving");
      playPreflightEntry();
    }, 170);
  } else {
    updatePreflight(nextIndex);
    playPreflightEntry();
  }
}

preflightBack.addEventListener("click", () => renderPreflight(preflightIndex - 1, true));
preflightNext.addEventListener("click", () => {
  if (preflightIndex === 4) {
    showScreen("today");
  } else {
    renderPreflight(preflightIndex + 1, true);
  }
});

renderPreflight(preflightIndex);

function hashNoise(x, y, seed = 0) {
  const value = Math.sin(x * 127.1 + y * 311.7 + seed * 47.3) * 43758.5453;
  return value - Math.floor(value);
}

function drawDither(canvas, time = 0) {
  const rect = canvas.getBoundingClientRect();
  if (!rect.width || !rect.height) return;

  const dpr = Math.min(2, window.devicePixelRatio || 1);
  const width = Math.round(rect.width * dpr);
  const height = Math.round(rect.height * dpr);
  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width;
    canvas.height = height;
  }

  const ctx = canvas.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, rect.width, rect.height);
  ctx.fillStyle = "#F4F1E8";
  ctx.fillRect(0, 0, rect.width, rect.height);

  const mode = canvas.dataset.mode || "idle";
  const step = mode === "meeting" ? 5 : 6;
  const animatedTime = mode.includes("voice") ? time * 0.0012 : time * 0.0004;

  for (let y = -step; y < rect.height + step; y += step) {
    for (let x = -step; x < rect.width + step; x += step) {
      const nx = x / rect.width;
      const ny = y / rect.height;
      const grain = hashNoise(x / step, y / step, mode.length);
      let cobalt = 0;
      let coral = 0;
      let ink = 0;

      if (mode === "meeting") {
        const upper = 0.33 + Math.sin(nx * 8 + 0.4) * 0.08;
        const lower = 0.7 + Math.sin(nx * 11 + 1.7) * 0.06;
        cobalt = Math.exp(-Math.pow(ny - upper, 2) / 0.012) * (0.42 + nx * 0.36);
        coral = Math.exp(-Math.pow(ny - lower, 2) / 0.01) * (0.76 - nx * 0.24);
        ink = Math.exp(-Math.pow(ny - 0.53, 2) / 0.02) * 0.15;
      } else if (mode === "preflight" || mode === "preflight-intro") {
        const leftField = Math.exp(-((nx - 0.12) ** 2 + (ny - 0.18) ** 2) / 0.16);
        const rightField = Math.exp(-((nx - 0.88) ** 2 + (ny - 0.82) ** 2) / 0.18);
        const convergence = Math.exp(-Math.pow(Math.hypot(nx - 0.5, ny - 0.5) - (0.16 + Math.sin(animatedTime * 2) * 0.015), 2) / 0.005);
        cobalt = leftField * 0.42 + convergence * 0.16;
        coral = rightField * 0.44 + convergence * 0.13;
        ink = Math.exp(-((nx - 0.5) ** 2 + (ny - 0.52) ** 2) / 0.24) * 0.08;
      } else if (mode === "preflight-access") {
        const orbitAngle = animatedTime * 0.9;
        const orbitRadius = 0.27;
        for (let nodeIndex = 0; nodeIndex < 3; nodeIndex += 1) {
          const angle = orbitAngle + nodeIndex * ((Math.PI * 2) / 3);
          const nodeX = 0.5 + Math.cos(angle) * orbitRadius;
          const nodeY = 0.5 + Math.sin(angle) * orbitRadius;
          const field = Math.exp(-((nx - nodeX) ** 2 + (ny - nodeY) ** 2) / 0.018);
          if (nodeIndex === 1) coral += field * 0.48;
          else cobalt += field * 0.4;
        }
        const halo = Math.exp(-Math.pow(Math.hypot(nx - 0.5, ny - 0.5) - 0.28, 2) / 0.004);
        ink = halo * 0.11;
      } else if (mode === "preflight-engines") {
        const leftEngine = Math.exp(-((nx - 0.24) ** 2 + (ny - 0.5) ** 2) / 0.055);
        const rightEngine = Math.exp(-((nx - 0.76) ** 2 + (ny - 0.5) ** 2) / 0.055);
        const bridge = Math.exp(-Math.pow(ny - (0.5 + Math.sin(nx * 12 + animatedTime * 3) * 0.018), 2) / 0.0028);
        const packetX = 0.27 + ((animatedTime * 0.16) % 0.46);
        const packet = Math.exp(-((nx - packetX) ** 2 + (ny - 0.5) ** 2) / 0.004);
        cobalt = leftEngine * 0.34 + bridge * 0.24 + packet * 0.58;
        coral = rightEngine * 0.38 + bridge * 0.16;
        ink = bridge * 0.08;
      } else if (mode === "preflight-voice") {
        const waveA = 0.32 + Math.sin(nx * 9 + animatedTime * 4.2) * 0.16;
        const waveB = 0.68 + Math.sin(nx * 7 - animatedTime * 3.4 + 1.5) * 0.15;
        cobalt = Math.exp(-Math.pow(ny - waveA, 2) / 0.012) * (0.52 + nx * 0.4);
        coral = Math.exp(-Math.pow(ny - waveB, 2) / 0.011) * (0.88 - nx * 0.28);
        ink = Math.exp(-Math.pow(ny - 0.5, 2) / 0.018) * 0.13;
      } else if (mode === "preflight-ready") {
        const radius = Math.hypot(nx - 0.5, ny - 0.5);
        const pulse = 0.22 + Math.sin(animatedTime * 2.2) * 0.012;
        const ring = Math.exp(-Math.pow(radius - pulse, 2) / 0.0045);
        cobalt = ring * (nx < 0.54 ? 0.54 : 0.18);
        coral = ring * (nx >= 0.46 ? 0.52 : 0.16);
        ink = Math.exp(-radius * 8) * 0.22;
      } else if (mode === "insights") {
        const trend = 0.72 - nx * 0.38 + Math.sin(nx * 12 + 0.8) * 0.07;
        const echo = 0.82 - nx * 0.2 + Math.sin(nx * 8 + 2.1) * 0.05;
        cobalt = Math.exp(-Math.pow(ny - trend, 2) / 0.008) * (0.46 + nx * 0.38);
        coral = Math.exp(-Math.pow(ny - echo, 2) / 0.006) * (0.42 - nx * 0.18);
        ink = Math.exp(-Math.pow(ny - 0.78, 2) / 0.018) * 0.08;
      } else if (mode === "process") {
        const radius = Math.hypot(nx - 0.5, ny - 0.5);
        const ring = Math.exp(-Math.pow(radius - 0.24, 2) / 0.005);
        cobalt = ring * 0.64;
        coral = Math.exp(-Math.pow(radius - 0.12, 2) / 0.004) * 0.54;
        ink = Math.exp(-radius * 8) * 0.24;
      } else {
        const waveA = 0.3 + Math.sin(nx * 8 + animatedTime * 4) * 0.13;
        const waveB = 0.72 + Math.sin(nx * 6 - animatedTime * 3 + 1.8) * 0.12;
        const energy = mode === "voice" ? 1 : 0.66;
        cobalt = Math.exp(-Math.pow(ny - waveA, 2) / 0.014) * energy * (0.38 + nx * 0.5);
        coral = Math.exp(-Math.pow(ny - waveB, 2) / 0.012) * energy * (0.82 - nx * 0.3);
        ink = Math.exp(-Math.pow(ny - 0.51, 2) / 0.02) * 0.12;
      }

      let color = null;
      let strength = 0;
      if (grain < cobalt) {
        color = "#2449F8";
        strength = cobalt;
      } else if (grain < coral) {
        color = "#FF7048";
        strength = coral;
      } else if (grain < ink) {
        color = "#171713";
        strength = ink;
      }

      if (color) {
        const size = strength > 0.64 ? 4 : strength > 0.32 ? 3 : 2;
        ctx.fillStyle = color;
        ctx.globalAlpha = 0.42 + Math.min(0.58, strength);
        ctx.fillRect(Math.round(x), Math.round(y), size, size);
      }
    }
  }

  ctx.globalAlpha = 1;
}

let animationFrame = null;

function drawAllDither(time = 960) {
  document.querySelectorAll(".dither-canvas").forEach((canvas) => drawDither(canvas, time));
}

function animateDither(time) {
  const activeScreen = document.querySelector(".screen.is-active");
  const capture = document.body.classList.contains("is-capture") && !motionCapture;
  const morphing = preflightMain?.classList.contains("is-morphing");
  if (!capture && !reducedMotion.matches && !morphing) {
    activeScreen?.querySelectorAll('.dither-canvas[data-mode="voice"], .dither-canvas[data-mode="process"], .dither-canvas[data-mode^="preflight-"]').forEach((canvas) => drawDither(canvas, time));
  }
  animationFrame = requestAnimationFrame(animateDither);
}

const resizeObserver = new ResizeObserver(() => drawAllDither());
document.querySelectorAll(".dither-canvas").forEach((canvas) => resizeObserver.observe(canvas));

showScreen(params.get("screen") || "today", { initial: true });
drawAllDither();
animationFrame = requestAnimationFrame(animateDither);

document.fonts.ready.then(() => {
  drawAllDither();
  document.documentElement.classList.add("fonts-ready");
  window.__prototypeReady = true;
});
