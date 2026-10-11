import { Elt } from '../doc'
import { Wordgard, Decoration, KeyBinding } from '../editor'
import { GardState, Transaction, GardSelection } from '../state'
import { ImageSize, ImageAlt, Image, Figure, CaptionedFigure } from '../types'
import { Command, Menu } from '../command'
import { imagePhrases } from '../phrases'
import { imageDialog, insertImage, activeImage, imageUploader } from './imagedialog'

function baseSupport(): GardState.Extension {
  return [GardState.schemaElement.of(ImageAlt), image.button, imageDialog, image.keyBinding, image.dropHandler]
}

/**
 * Returns extensions that add support for inline images. That
 * includes the {@link Image schema element}, the {@link ImageAlt
 * alt text mark}, the {@link image.button menu button}, a {@link
 * image.keyBinding key binding}, and a {@link image.dropHandler
 * drop handler for image files}.
 */
export function image(): GardState.Extension {
  return [GardState.schemaElement.of(Image), baseSupport()]
}

/**
 * Support for block figures. Adds the same support extensions as
 * {@link image}, but includes the {@link Figure} schema element instead.
 */
export function figure(
  conf: {
    /** When enabled, also support {@link CaptionedFigure captioned figures}. */
    captioned?: boolean
  } = {}
): GardState.Extension {
  return [
    GardState.schemaElement.of(Figure),
    conf?.captioned ? [GardState.schemaElement.of(CaptionedFigure)] : [],
    baseSupport()
  ]
}

/**
 * Add resizing functionality for images and figures. Includes the
 * {@link ImageSize} mark, the {@link imageResizing.dragHandle drag
 * handle}, and {@link imageResizing.keyBindings key bindings}.
 */
export function imageResizing(): GardState.Extension {
  return [GardState.schemaElement.of(ImageSize), imageResizing.keyBindings, imageResizing.dragHandle]
}

const resizeTheme = Wordgard.theme({
  '.wg-resize-hover': {
    display: 'inline-block',
    lineHeight: '0.1',
    position: 'relative'
  },
  '.wg-resize-handle': {
    position: 'absolute',
    right: '1px',
    bottom: '1px',
    width: 'min(60%, 20px)',
    height: 'min(60%, 20px)'
  },
  '.wg-resize-handle-active': {
    cursor: 'nwse-resize'
  }
})

const setResizing = Transaction.Effect.define<{ target: number; resizing: number }>({
  map: (value, mapping) => {
    const newPos = mapping.mapPos(value.target, 1, 'after')
    return newPos == null ? undefined : { target: newPos, resizing: value.resizing }
  }
})

const handleElt = Elt.mk('svg:svg', { class: 'wg-resize-handle', viewBox: '0 0 20 20' }, [
  Elt.mk('svg:path', { d: 'M20 0L0 20M20 5L5 20M20 10L10 20', stroke: '#000000aa', 'stroke-width': '1.5' }),
  Elt.mk('svg:polygon', { points: '0,20 20,20 20,0', fill: 'transparent', class: 'wg-resize-handle-active' })
])

const resizeWrapper = Decoration.Point.wrapper(Elt.mk('span', { class: 'wg-resize-hover' }, [handleElt, 0]), {
  target: 'img'
})

const resizeState = GardState.Field.define<{ target: number; resizing: number; deco: Decoration.Point.Set }>({
  create: () => ({ target: -1, resizing: -1, deco: Decoration.Point.none }),
  update: (value, tr) => {
    for (const e of tr.effects) {
      if (e.is(setResizing)) {
        const { target, resizing } = e.value
        if (target < 0) return { target: -1, resizing: -1, deco: Decoration.Point.none }
        const deco: [Decoration.Point, number][] = [[resizeWrapper, target]]
        if (resizing > -1) {
          deco.push([Decoration.Point.attributes({ style: `width: ${resizing}px` }, { target: 'img' }), target])
        }
        return { target, resizing, deco: Decoration.Point.set(deco) }
      }
    }
    return value.target < 0 || !tr.docChanged
      ? value
      : { target: value.target, resizing: value.resizing, deco: value.deco.map(tr.changes) }
  }
})

const MIN_SIZE = 10

function imageNode(wg: Wordgard, pos: number) {
  const dom = wg.nodeDOM(pos)!
  return dom.nodeName == 'IMG' ? dom : dom.querySelector('img[src]')!
}

const resizeHandlers = [
  Wordgard.domEventHandler('mousedown', (event, wg) => {
    const resizing = wg.state.field(resizeState)
    if (resizing.target < 0) return
    for (let dom = event.target as Element; ;) {
      if (dom.classList.contains('wg-resize-handle-active')) break
      const next = dom.parentNode as Element | null
      if (!next || next == wg.contentDOM) return
      dom = next
    }
    const node = wg.state.doc.nodeAt(resizing.target)!
    const width = node.tag.mark(ImageSize) ?? imageNode(wg, resizing.target).getBoundingClientRect().width
    wg.dispatch({ effects: setResizing.of({ target: resizing.target, resizing: width }) })
    event.preventDefault()
  }),
  Wordgard.domEventHandler('mousemove', (event, wg) => {
    const resizing = wg.state.field(resizeState)
    if (resizing.resizing > -1) {
      const dom = imageNode(wg, resizing.target)
      const width = event.clientX - dom.getBoundingClientRect().left
      if (width >= MIN_SIZE && Math.abs(width - resizing.resizing) >= 1) {
        wg.dispatch({ effects: setResizing.of({ target: resizing.target, resizing: width }) })
      }
    } else {
      const elt = (event.target as HTMLElement).closest('img, .wg-resize-handle')
      const node = elt && wg.nodeFromDOM(elt)
      const target = node && wg.state.schema.markAllowed(ImageSize, node.node.type) ? node.pos : -1
      if (target != resizing.target) wg.dispatch({ effects: setResizing.of({ target, resizing: -1 }) })
    }
  }),
  Wordgard.domEventHandler('mouseup', (_event, wg) => {
    const resizing = wg.state.field(resizeState)
    if (resizing.resizing < 0) return
    wg.dispatch({
      effects: setResizing.of({ target: resizing.target, resizing: -1 }),
      changes: { from: resizing.target, add: ImageSize.of(Math.round(resizing.resizing)) }
    })
  })
]

export namespace imageResizing {
  /**
   * Returns a command that resizes the currently selected image or
   * figure. When `relative` is fale, `by` indicates a pixel amount,
   * which can be positive or negative. When it is true, `by` is a
   * scaling factor, which should be between 0 and 1 to shrink the
   * image, and greater than1 to grow it.
   */
  export const resizeCommand =
    (by: number, relative = false): Command =>
    wg => {
      const { selection } = wg.state
      if (selection instanceof GardSelection.Node && wg.state.schema.markAllowed(ImageSize, selection.node.type)) {
        const curWidth =
          selection.node.mark(ImageSize) ?? imageNode(wg, wg.state.selection.from).getBoundingClientRect().width
        const newWidth = Math.max(MIN_SIZE, relative ? curWidth * by : curWidth + by)
        if (newWidth != curWidth) {
          wg.dispatch({
            changes: { from: wg.state.selection.from, add: ImageSize.of(newWidth) },
            userEvent: 'image.resize'
          })
          return true
        }
      }
      return false
    }

  /**
   * Binds `Ctrl-Alt-l` (`Ctrl-Cmd-l` on Mac) to grow an image by
   * 10%, and `Ctrl-Alt-k` (`Ctrl-Cmd-k` on Mac) to shrink it by 10%.
   */
  export const keyBindings = [
    KeyBinding.of({ key: 'Ctrl-Alt-l', mac: 'Ctrl-Cmd-l', run: resizeCommand(1.1, true) }),
    KeyBinding.of({ key: 'Ctrl-Alt-k', mac: 'Ctrl-Cmd-k', run: resizeCommand(0.9091, true) })
  ]

  /**
   * Extension that displays a drag handle when the user hovers over
   * an image or figure, which can be dragged to adjust the element's
   * width.
   */
  export const dragHandle: GardState.Extension = [
    GardState.prec.high(resizeHandlers),
    resizeState,
    Decoration.Point.source.of(s => s.field(resizeState).deco),
    resizeTheme
  ]
}

export namespace image {
  /** Binds `Ctrl-Alt-i` to open the image insert/update dialog. */
  export const keyBinding = KeyBinding.of({ key: 'Ctrl-Alt-i', mac: 'Ctrl-Cmd-i', run: insertImage })

  /**
   * A menu button that opens a dialog to insert an image or figure,
   * or to adjust the currently selected image or figure.
   */
  export const button = Menu.Button.define({
    run: insertImage,
    active: state => !!activeImage(state.sel),
    label: {
      icon: 'M38 34a9 9 0 1 1-19 0 9 9 0 0 1 19 0M9 13A9 9 0 0 0 0 22v56A9 9 0 0 0 9 88h81a9 9 0 0 0 9-9v-56A9 9 0 0 0 91 13zm81 6a3 3 0 0 1 3 3v38l-24-12a3 3 0 0 0-4 1l-23 23-17-11a3 3 0 0 0-4 0L6 75v3L6 78v-56a3 3 0 0 1 3-3z'
    },
    description: imagePhrases.ref('insert_image'),
    enable: s => !s.readOnly,
    parent: Menu.Group.insert,
    rank: 30
  })

  /**
   * A custom drop handler that checks whether an image file is being
   * dropped. When an {@link image.uploader uploader} has been
   * defined, it will feed the file to that, and insert an image with
   * the resulting URI when it finishes.
   */
  export const dropHandler = GardState.prec.lowest(
    Wordgard.domEventHandler('drop', (event, wg) => {
      const { state } = wg
      const upload = state.facet(imageUploader)[0]
      const type = state.schema.has(Image) ? Image : state.schema.has(Figure) ? Figure : null
      if (state.readOnly || !type || !upload || !event.dataTransfer) return false
      const files = event.dataTransfer.files,
        uploads: Promise<string>[] = []
      for (let i = 0; i < files.length; i++) {
        const file = files[i]!
        if (file.type.startsWith('image/')) uploads.push(upload(file, wg, () => {}))
      }
      if (!uploads.length) return false
      const dropPos = { x: event.clientX, y: event.clientY }
      Promise.all(uploads).then(
        urls => {
          wg.dispatch({
            changes: { from: wg.posAtCoords(dropPos).pos, insert: urls.map(u => type.of(u)), fit: true },
            userEvent: 'drop.image'
          })
        },
        err => {
          Wordgard.logException(state, err, 'Dropped image upload')
        }
      )
      return true
    })
  )

  /** The command that opens the image dialog. */
  export const insert = insertImage

  /**
   * A facet that you can use to register a handler for image
   * uploads. Your function will be passed a file object, an editor
   * instance, and a function that it can call to indicate progress,
   * and should return a promise that resolves to a URI for the
   * uploaded image.
   */
  export const uploader = imageUploader
}
