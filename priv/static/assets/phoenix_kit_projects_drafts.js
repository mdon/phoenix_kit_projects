/*
 * phoenix_kit_projects — the task list's draft row.
 *
 * PkpDraft: the row Enter opens on a card list (`OutlineList.draft_row/1`).
 * What is typed here is no task until it is written: Enter writes it and
 * opens the next draft below; Tab / Shift+Tab move the draft in and out a
 * level; Esc, Enter on an empty draft, or leaving it empty drop it; leaving
 * it with text writes it. A pasted list goes in where the draft stands.
 *
 * Every draft is a new input with a key of its own (`data-key`); the server
 * acts on an event only while that key is the open draft's, so a blur that
 * fires as the row is replaced cannot write a task twice.
 */
(function () {
  "use strict";

  // "  - [x] Buy milk" → {text, depth, done} — the same reading of a pasted
  // list as the typed list's (phoenix_kit_projects.js).
  function parsePasted(text) {
    var raw = text.replace(/\r\n?/g, "\n").split("\n");
    var rows = [];
    raw.forEach(function (line) {
      if (line.trim() === "") return;
      var lead = line.match(/^[\t ]*/)[0];
      var tabs = (lead.match(/\t/g) || []).length;
      var spaces = lead.length - tabs;
      var rest = line.slice(lead.length);
      var done = false;
      var m = rest.match(/^(?:[-*+•◦‣]|\d{1,3}[.)])\s+/);
      if (m) rest = rest.slice(m[0].length);
      m = rest.match(/^\[( |x|X)?\]\s*/);
      if (m) {
        done = /x/i.test(m[1] || "");
        rest = rest.slice(m[0].length);
      }
      rest = rest.trim();
      if (rest === "") return;
      rows.push({ text: rest, indent: tabs * 4 + spaces, done: done });
    });
    // Indent widths → levels: each distinct width seen is one level deeper
    // than the nearest smaller one above it.
    var stack = [];
    rows.forEach(function (row) {
      while (stack.length && stack[stack.length - 1] >= row.indent) stack.pop();
      row.depth = stack.length;
      stack.push(row.indent);
    });
    return rows;
  }

  var Draft = {
    mounted: function () {
      var self = this;
      var el = this.el;
      this.key = el.dataset.key;
      // Set once this draft has been handed to the server: nothing after
      // that (the blur as the row goes) may hand it over again.
      this.done = false;

      el.addEventListener("keydown", function (e) {
        if (self.done) return;
        if (e.key === "Enter") {
          e.preventDefault();
          self.finish(true);
        } else if (e.key === "Escape") {
          e.preventDefault();
          self.drop(true);
        } else if (e.key === "Tab") {
          e.preventDefault();
          self.done = true;
          self.pushEvent("outline_draft_nest", { key: self.key, dir: e.shiftKey ? "out" : "in", text: el.value });
          // A draft that cannot move (nothing above to go under) stays open.
          setTimeout(function () { if (!self.gone) self.done = false; }, 400);
        }
      });

      el.addEventListener("paste", function (e) {
        var plain = (e.clipboardData && e.clipboardData.getData("text/plain")) || "";
        if (plain.indexOf("\n") === -1 || self.done) return;
        e.preventDefault();
        var rows = parsePasted(plain);
        if (rows.length === 0) return;
        self.done = true;
        self.pushEvent("outline_draft_paste", { key: self.key, text: el.value, lines: rows });
      });

      el.addEventListener("blur", function () {
        if (self.done || self.gone) return;
        self.finish(false);
      });

      el.focus();
      var end = el.value.length;
      el.setSelectionRange(end, end);
    },

    // Enter (next = true: the next draft opens below) or leaving the row.
    finish: function (next) {
      var text = this.el.value.replace(/\s+/g, " ").trim();
      if (text === "") { this.drop(next); return; }
      this.done = true;
      this.pushEvent("outline_draft_save", { key: this.key, text: text, next: next, refocus: false });
    },

    // refocus: the cursor goes back to the row above (Esc, Enter on empty);
    // not when the person clicked somewhere else.
    drop: function (refocus) {
      this.done = true;
      this.pushEvent("outline_draft_cancel", { key: this.key, refocus: !!refocus });
    },

    destroyed: function () {
      this.gone = true;
    }
  };

  window.PhoenixKitProjectsDraftHooks = { PkpDraft: Draft };
})();
