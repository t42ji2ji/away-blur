// The page does what the app does: go still and it frosts, with the app's own
// cat and letters in the middle; move and it clears.
import { CAT, FONT } from './art.js';

const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
const rand = (lo, hi) => lo + Math.random() * (hi - lo);
const pick = list => list[Math.floor(Math.random() * list.length)];
const clamp = (x, lo, hi) => Math.min(Math.max(x, lo), hi);
const seconds = () => performance.now() / 1000;
const css = name => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
const rgb = hex => [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16));

// ---- The cat ---------------------------------------------------------------

const stamps = CAT.packed.map(hex => {
  const bits = new Uint8Array(CAT.width * CAT.height);
  for (let i = 0; i < hex.length; i++) {
    const nibble = parseInt(hex[i], 16);
    for (let bit = 0; bit < 4; bit++) if (nibble & (8 >> bit)) bits[i * 4 + bit] = 1;
  }
  return bits;
});

const anim = Object.fromEntries(CAT.animations.map(a =>
  [a.name, { ...a, count: a.frames[1] - a.frames[0] }]));

const BEATS = ['stretch', 'shake', 'yawn', 'flop', 'roll', 'situp', 'paw', 'walk', 'run', 'pounce'];
const SLEEPY_BEATS = ['yawn', 'roll', 'stretch'];
const AWAKE_GAP = [12, 30];      // the app's own gap: mostly it sits
const ASLEEP_GAP = [90, 240];
const SLEEP_AFTER = 600;
const resting = away => away > SLEEP_AFTER ? anim.sleep : anim.idle;

// CatPlayer.swift, line for line.
class CatPlayer {
  anim = anim.idle;
  frame = 0;
  blinking = false;
  #blinkAt = 0;
  #blinkUntil = 0;
  #frameAt = 0;
  #left = -1;
  #beatAt = 0;

  get stamp() {
    return this.blinking && this.anim.blink
      ? this.anim.blink[0] + this.frame
      : this.anim.frames[0] + this.frame;
  }

  begin(now) {
    this.anim = anim.idle;
    this.frame = 0;
    this.#frameAt = now;
    this.#left = -1;
    this.#beatAt = now + rand(...AWAKE_GAP);
  }

  #play(name, now) {
    const a = anim[name];
    this.anim = a;
    this.frame = 0;
    this.#frameAt = now;
    this.#left = a.loops ? a.count * Math.max(1, Math.round(2.5 / (a.count / a.fps))) : a.count;
  }

  #rest(now, away) {
    this.anim = resting(away);
    this.frame = 0;
    this.#frameAt = now;
    this.#left = -1;
  }

  /** One tick; true when the frame changed. `held` loops one animation. */
  step(now, away, held = '') {
    const wasBlinking = this.blinking;
    if (this.anim.blink) {
      if (now >= this.#blinkAt) {
        this.#blinkUntil = now + 0.13;
        this.#blinkAt = now + rand(2.4, 6.5);
      }
      this.blinking = now < this.#blinkUntil;
    } else {
      this.blinking = false;
    }
    if (held) {
      if (this.anim.name !== held) {
        this.anim = anim[held];
        this.frame = 0;
        this.#frameAt = now;
        this.#left = -1;
      }
    } else {
      const asleep = resting(away) === anim.sleep;
      if (now >= this.#beatAt) {
        if (this.#left < 0) this.#play(pick(asleep ? SLEEPY_BEATS : BEATS), now);
        this.#beatAt = now + rand(...(asleep ? ASLEEP_GAP : AWAKE_GAP));
      }
      if (this.#left < 0 && this.anim !== resting(away)) this.#rest(now, away);
    }
    if (now - this.#frameAt < 1 / this.anim.fps) return this.blinking !== wasBlinking;
    this.#frameAt = now;
    if (this.#left >= 0) {
      this.#left -= 1;
      if (this.#left <= 0) {
        this.#rest(now, away);
        return true;
      }
    }
    this.frame = (this.frame + 1) % this.anim.count;
    return true;
  }
}

function drawBits(ctx, bits, columns, x, y, cell) {
  const rows = bits.length / columns;
  for (let row = 0; row < rows; row++) {
    for (let column = 0; column < columns; column++) {
      if (!bits[row * columns + column]) continue;
      let run = 1;
      while (column + run < columns && bits[row * columns + column + run]) run++;
      ctx.fillRect(x + column * cell, y + row * cell, run * cell, cell);
      column += run - 1;
    }
  }
}

// ---- The letters -----------------------------------------------------------

const BLANK = Array(7).fill('.....');

/** PixelFont.bitmap: every stem drawn again one column to the right. */
function letters(text) {
  const characters = [...text.toUpperCase()];
  const columns = Math.max(1, characters.length * 7 - 1);
  const bits = new Uint8Array(columns * 7);
  characters.forEach((character, index) => {
    (FONT[character] || BLANK).forEach((line, row) => {
      for (let column = 0; column < 5; column++) {
        if (line[column] !== '#') continue;
        bits[row * columns + index * 7 + column] = 1;
        bits[row * columns + index * 7 + column + 1] = 1;
      }
    });
  });
  return { bits, columns };
}

function lettersSVG(text, cell) {
  const { bits, columns } = letters(text);
  let d = '';
  for (let row = 0; row < 7; row++) {
    for (let column = 0; column < columns; column++) {
      if (!bits[row * columns + column]) continue;
      let run = 1;
      while (column + run < columns && bits[row * columns + column + run]) run++;
      d += `M${column} ${row}h${run}v1h-${run}z`;
      column += run - 1;
    }
  }
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', `0 0 ${columns} 7`);
  svg.setAttribute('width', columns * cell);
  svg.setAttribute('height', 7 * cell);
  svg.setAttribute('shape-rendering', 'crispEdges');
  svg.setAttribute('aria-hidden', 'true');
  svg.innerHTML = `<path fill="currentColor" d="${d}"/>`;
  return svg;
}

function pixelEntry(element) {
  const text = element.textContent.trim();
  const said = document.createElement('span');
  said.className = 'sr';
  said.textContent = text;
  return { element, text, said };
}
const pixelText = [...document.querySelectorAll('.px')].map(pixelEntry);

function setLetters() {
  for (const { element, text, said } of pixelText) {
    // A whole number of pixels per letter pixel, never a fraction. The letters
    // already there are cleared before the space they have is measured, or a
    // heading that has grown can never find out that the window shrank.
    let cell = Number(element.dataset.cell);
    if (element.hasAttribute('data-fit')) {
      element.replaceChildren();
      cell = clamp(Math.floor(element.clientWidth / (text.length * 7 - 1)), 3, 17);
    }
    element.replaceChildren(said, lettersSVG(text, cell));
  }
}

// ---- The line under the cat ------------------------------------------------

const CHATTER = [
  'NOBODY HERE', 'STILL WATCHING', 'I TOUCHED NOTHING', 'YOUR SEAT IS COLD',
  'TAKE YOUR TIME', 'I AM NOT ASLEEP', 'NOTHING HAS CHANGED', 'THE SCREEN IS SAFE',
];
const ARRIVING = 0.65, HOLDING = 5.2, LEAVING = 0.45;
const SCRAMBLE = [...'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#%*+-=/<>:.'];

function awayLine(away) {
  const minutes = Math.floor(away / 60);
  if (minutes === 0) return 'AWAY A MOMENT';
  if (minutes === 1) return 'AWAY 1 MINUTE';
  if (minutes < 60) return `AWAY ${minutes} MINUTES`;
  const hours = Math.floor(minutes / 60), rest = minutes % 60;
  return rest ? `AWAY ${hours}H ${rest}M` : `AWAY ${hours}H`;
}

function clockLine() {
  const now = new Date();
  return [now.getHours(), now.getMinutes()].map(n => String(n).padStart(2, '0')).join(':');
}

function scrambled(text, progress, seed) {
  if (progress >= 1) return text;
  const characters = [...text];
  const settled = Math.floor(characters.length * Math.max(progress, 0) * 1.35);
  let state = seed >>> 0;
  return characters.map((character, index) => {
    if (index < settled || character === ' ') return character;
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return SCRAMBLE[(state >>> 8) % SCRAMBLE.length];
  }).join('');
}

const erased = (text, progress) =>
  text.slice(0, Math.round(text.length * (1 - clamp(progress, 0, 1))));

// ---- The frost -------------------------------------------------------------

// Radii are CSS blur deviations, chosen to match the app's radii by eye.
const LOOKS = {
  privacy: { blur: 30, dim: 0.45, wash: 0, fadeIn: 0.45, fadeOut: 0.14 },
  ambient: { blur: 14, dim: 0.12, wash: 0.35, fadeIn: 1.6, fadeOut: 0.8 },
};

const frost = document.querySelector('.frost');
const canvas = frost.querySelector('canvas');
const ctx = canvas.getContext('2d');
const player = new CatPlayer();

let lookName = 'ambient';
let look = LOOKS.ambient;
let phase = 'clear';            // clear, in, out
let progress = 0;
let rampFrom = 0, rampAt = 0;
let graceUntil = 0, awaySince = 0;
let wash = [0, 0, 0], catInk = '#111111';
let boil = [0, 0], boiledAt = 0;
let line = { since: 0, turn: 0, lines: [] };
let macInView = true;

/** The wallpaper's average colour, and so which way the cat is drawn. */
function readScreen() {
  const average = rgb(css('--wall-average'));
  wash = average;
  const light = (0.299 * average[0] + 0.587 * average[1] + 0.114 * average[2]) / 255;
  catInk = light * (1 - look.dim) > 0.45 ? css('--ink') : css('--paper');
}

function sizeCanvas() {
  const dpr = window.devicePixelRatio || 1;
  canvas.width = Math.round(frost.clientWidth * dpr);
  canvas.height = Math.round(frost.clientHeight * dpr);
}

function goAway(name, now, grace = 0, instantly = false) {
  if (phase !== 'clear') return;
  lookName = name;
  look = LOOKS[name];
  phase = 'in';
  rampFrom = instantly || reduced ? 1 : 0;
  rampAt = now;
  graceUntil = now + grace;
  awaySince = now;
  line = { since: 0, turn: 0, lines: [] };
  player.begin(now);
  frost.classList.add('up');
  sizeCanvas();
  readScreen();
}

/** Going away is not reversible: once the fade-out starts it runs to the end. */
function comeBack(now) {
  if (phase !== 'in') return;
  phase = 'out';
  rampFrom = progress;
  rampAt = now;
}

function applyLook() {
  // The radii are the app's, which are for a whole screen; this one is a few
  // hundred pixels tall, and a blur that does not scale with it would eat the
  // picture whole.
  const blur = look.blur * (frost.clientHeight / 900) * progress ** 1.45;
  const dim = look.dim * progress ** 0.9;
  frost.style.webkitBackdropFilter = frost.style.backdropFilter = `blur(${blur.toFixed(2)}px)`;
  frost.style.background =
    `linear-gradient(rgb(0 0 0 / ${dim.toFixed(3)}) 0 0), rgb(${wash.join(' ')} / ${(look.wash * progress).toFixed(3)})`;
}

const ease = p => {
  const x = clamp((p - 0.3) / 0.5, 0, 1);
  return x * x * (3 - 2 * x);
};

function currentLine(now) {
  if (!line.since || now - line.since > ARRIVING + HOLDING + LEAVING) {
    if (line.since) line.turn += 1;
    line.since = now;
    if (!line.lines.length || line.turn % line.lines.length === 0) {
      line.lines = [awayLine(now - awaySince), clockLine(), pick(CHATTER)];
      line.turn = 0;
    }
  }
  const text = line.lines[line.turn % line.lines.length];
  const elapsed = now - line.since;
  if (reduced) return text;
  if (elapsed < ARRIVING) return scrambled(text, elapsed / ARRIVING, Math.floor(now * 14));
  if (elapsed < ARRIVING + HOLDING) return text;
  return erased(text, (elapsed - ARRIVING - HOLDING) / LEAVING);
}

function drawFrost(now) {
  if (!reduced) player.step(now, now - awaySince);
  if (!reduced && now - boiledAt >= 0.33) {
    boiledAt = now;
    boil = [rand(-1, 1), rand(-1, 1)];
  }
  const { width, height } = canvas;
  ctx.clearRect(0, 0, width, height);
  ctx.globalAlpha = ease(progress);
  ctx.fillStyle = catInk;

  // BlurController's placement: the frame is a fifth of the screen high, the
  // line hangs eight cat pixels under the resting cat's feet.
  const cell = Math.max(2, Math.floor(height * 0.2 / CAT.height));
  const x = Math.round((width - CAT.width * cell) / 2 + Math.round(boil[0] * cell));
  const y = Math.round((height - CAT.height * cell) / 2 + Math.round(boil[1] * cell));
  drawBits(ctx, stamps[player.stamp], CAT.width, x, y, cell);

  const text = currentLine(now);
  if (!text) return;
  const { bits, columns } = letters(text);
  let lineCell = Math.max(2, Math.round(cell * 0.45));
  while (lineCell > 2 && columns * lineCell > width * 0.9) lineCell -= 1;
  const feet = (height + CAT.height * cell) / 2 - (CAT.height - 1 - CAT.baseline) * cell;
  drawBits(ctx, bits, columns,
    Math.round((width - columns * lineCell) / 2), Math.round(feet + cell * 8), lineCell);
}

function tickFrost(now) {
  if (phase === 'clear') return;
  progress = phase === 'in'
    ? Math.min(1, rampFrom + (reduced ? 1 : (now - rampAt) / look.fadeIn))
    : Math.max(0, rampFrom - (reduced ? 1 : (now - rampAt) / look.fadeOut));
  if (phase === 'out' && progress === 0) {
    phase = 'clear';
    frost.classList.remove('up');
    frost.style.backdropFilter = frost.style.webkitBackdropFilter = frost.style.background = '';
    return;
  }
  applyLook();
  drawFrost(now);
}

const mac = document.querySelector('.mac');

/** A hand on the Mac takes the frost down; nothing else on the page does. */
function hand(e) {
  if (e.pointerType === 'touch') return;
  comeBack(seconds());
}

function gone(e) {
  if (e.pointerType === 'touch') return;
  goAway(lookName, seconds());
}

mac.addEventListener('pointerenter', hand);
mac.addEventListener('pointermove', e => { if (seconds() >= graceUntil) hand(e); });
mac.addEventListener('pointerleave', gone);
// A finger cannot hover, and the pointer it makes dies the moment it lifts,
// so touch gets a tap that turns the frost off and on.
mac.addEventListener('pointerdown', e => {
  if (e.pointerType !== 'touch') return;
  phase === 'clear' ? goAway(lookName, seconds()) : comeBack(seconds());
});
// Reaching it by keyboard is the same arrival as reaching it by hand.
mac.addEventListener('focusin', () => comeBack(seconds()));
mac.addEventListener('focusout', () => goAway(lookName, seconds()));

// ⌃⌥⌘B, as in the app: it puts the frost up, and a hand takes it back.
addEventListener('keydown', e => {
  if (!(e.ctrlKey && e.altKey && e.metaKey && e.code === 'KeyB')) return;
  e.preventDefault();
  goAway(lookName, seconds(), 1.5);
});

for (const button of document.querySelectorAll('.try')) {
  button.addEventListener('click', () => {
    const name = button.dataset.look;
    lookName = name;
    const showIt = () => {
      if (phase === 'clear') return goAway(name, seconds());
      look = LOOKS[name];              // already frosted: change it under them
      readScreen();
      applyLook();
    };
    if (macInView) return showIt();
    mac.scrollIntoView({ behavior: 'smooth', block: 'center' });
    setTimeout(showIt, 700);
  });
}

new IntersectionObserver(([entry]) => { macInView = entry.intersectionRatio >= 0.5; },
  { threshold: [0, 0.5, 1] }).observe(mac);

// ---- Every animation, held ------------------------------------------------

const cats = document.querySelector('.cats');
const held = CAT.animations.map(({ name }) => {
  const figure = document.createElement('figure');
  const view = document.createElement('canvas');
  const caption = document.createElement('figcaption');
  caption.className = 'px';
  caption.dataset.cell = '2';
  caption.textContent = name;
  figure.append(view, caption);
  cats.append(figure);
  pixelText.push(pixelEntry(caption));
  return { name, view, ctx: view.getContext('2d'), player: new CatPlayer() };
});
let catsInView = false;
let heldInk = '';
new IntersectionObserver(([entry]) => { catsInView = entry.isIntersecting; }).observe(cats);

function sizeHeld() {
  heldInk = css('--text');
  const dpr = window.devicePixelRatio || 1;
  const cell = Math.max(1, Math.round(3 * dpr));
  for (const cat of held) {
    cat.cell = cell;
    cat.view.width = CAT.width * cell;
    cat.view.height = CAT.height * cell;
    cat.view.style.width = `${CAT.width * cell / dpr}px`;
    cat.view.style.height = `${CAT.height * cell / dpr}px`;
    drawHeld(cat, reduced ? anim[cat.name].frames[0] + Math.floor(anim[cat.name].count / 2) : cat.player.stamp);
  }
}

function drawHeld(cat, stamp) {
  cat.ctx.clearRect(0, 0, cat.view.width, cat.view.height);
  cat.ctx.fillStyle = heldInk;
  drawBits(cat.ctx, stamps[stamp], CAT.width, 0, 0, cat.cell);
}

// ---- The menu bar ---------------------------------------------------------

function drawMenuCat() {
  const view = document.querySelector('.menucat');
  const bits = stamps[0];
  let top = CAT.height, bottom = 0, left = CAT.width, right = 0;
  bits.forEach((on, i) => {
    if (!on) return;
    const row = Math.floor(i / CAT.width), column = i % CAT.width;
    top = Math.min(top, row); bottom = Math.max(bottom, row);
    left = Math.min(left, column); right = Math.max(right, column);
  });
  const columns = right - left + 1, rows = bottom - top + 1;
  const cropped = new Uint8Array(columns * rows);
  for (let row = 0; row < rows; row++) {
    for (let column = 0; column < columns; column++) {
      cropped[row * columns + column] = bits[(top + row) * CAT.width + left + column];
    }
  }
  const dpr = window.devicePixelRatio || 1;
  const bar = document.querySelector('.bar').clientHeight || 24;
  const cell = Math.max(1, Math.round(bar * 0.72 / rows * dpr));
  view.width = columns * cell;
  view.height = rows * cell;
  view.style.width = `${columns * cell / dpr}px`;
  view.style.height = `${rows * cell / dpr}px`;
  const menuCtx = view.getContext('2d');
  menuCtx.fillStyle = '#ffffff';
  drawBits(menuCtx, cropped, columns, 0, 0, cell);
}

// ---- Running it -----------------------------------------------------------

function layout() {
  document.querySelector('.bar-clock').textContent = clockLine();
  setLetters();
  sizeHeld();
  drawMenuCat();
  if (phase !== 'clear') { sizeCanvas(); readScreen(); }
}

function frame() {
  const now = seconds();
  tickFrost(now);
  if (catsInView && !reduced) {
    for (const cat of held) if (cat.player.step(now, 0, cat.name)) drawHeld(cat, cat.player.stamp);
  }
  requestAnimationFrame(frame);
}

layout();
setInterval(layout, 60_000);
addEventListener('resize', layout);
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', layout);

document.querySelector('.hint').textContent = matchMedia('(hover: hover)').matches
  ? 'Move the pointer onto it.' : 'Tap it.';

// It opens the way the app leaves a screen nobody is at.
goAway('ambient', seconds(), 0, true);
requestAnimationFrame(frame);
