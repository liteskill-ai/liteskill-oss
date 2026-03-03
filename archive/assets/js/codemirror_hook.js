import {EditorView, basicSetup} from "codemirror"
import {EditorState} from "@codemirror/state"
import {markdown} from "@codemirror/lang-markdown"
import {languages} from "@codemirror/language-data"

const SectionEditor = {
  mounted() {
    const content = this.el.dataset.content || ""

    const state = EditorState.create({
      doc: content,
      extensions: [
        basicSetup,
        markdown({codeLanguages: languages}),
        EditorView.lineWrapping,
        EditorView.theme({
          "&": {maxHeight: "400px"},
          ".cm-scroller": {overflow: "auto"},
          "&.cm-focused": {outline: "none"}
        })
      ]
    })

    this.editor = new EditorView({
      state,
      parent: this.el.querySelector("[data-editor-target]")
    })

    this.editor.focus()

    const saveBtn = this.el.querySelector("[data-action='save']")
    if (saveBtn) {
      saveBtn.addEventListener("click", () => {
        const titleInput = this.el.querySelector("[data-title-input]")
        this.pushEvent("save_section", {
          "section-id": this.el.dataset.sectionId,
          title: titleInput ? titleInput.value : this.el.dataset.title,
          content: this.editor.state.doc.toString()
        })
      })
    }
  },

  destroyed() {
    if (this.editor) {
      this.editor.destroy()
      this.editor = null
    }
  }
}

const WikiEditor = {
  mounted() {
    const content = this.el.dataset.content || ""

    const state = EditorState.create({
      doc: content,
      extensions: [
        basicSetup,
        markdown({codeLanguages: languages}),
        EditorView.lineWrapping,
        EditorView.theme({
          "&": {maxHeight: "500px"},
          ".cm-scroller": {overflow: "auto"},
          "&.cm-focused": {outline: "none"}
        })
      ]
    })

    this.editor = new EditorView({
      state,
      parent: this.el.querySelector("[data-editor-target]")
    })

    const form = this.el.closest("form")
    if (form) {
      form.addEventListener("submit", () => {
        const hidden = form.querySelector("[data-editor-content]")
        if (hidden) {
          hidden.value = this.editor.state.doc.toString()
        }
      })
    }
  },

  destroyed() {
    if (this.editor) {
      this.editor.destroy()
      this.editor = null
    }
  }
}

export {SectionEditor, WikiEditor}
