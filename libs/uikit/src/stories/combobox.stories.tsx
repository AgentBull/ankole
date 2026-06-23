import type { Meta, StoryObj } from '@storybook/react'

import {
  Combobox,
  ComboboxChip,
  ComboboxChips,
  ComboboxChipsInput,
  ComboboxContent,
  ComboboxEmpty,
  ComboboxInput,
  ComboboxItem,
  ComboboxList,
  ComboboxValue,
  useComboboxAnchor
} from '../components/combobox'

const FRUITS = [
  { value: 'apple', label: 'Apple' },
  { value: 'banana', label: 'Banana' },
  { value: 'cherry', label: 'Cherry' },
  { value: 'date', label: 'Date' },
  { value: 'elderberry', label: 'Elderberry' },
  { value: 'fig', label: 'Fig' },
  { value: 'grape', label: 'Grape' }
]

const meta = {
  title: 'Components/Combobox',
  component: Combobox
} satisfies Meta<typeof Combobox>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  render: () => (
    <div className="w-72">
      <Combobox items={FRUITS} itemToStringValue={item => item.value}>
        <ComboboxInput placeholder="Pick a fruit…" />
        <ComboboxContent>
          <ComboboxList>
            <ComboboxEmpty>No results</ComboboxEmpty>
            {FRUITS.map(fruit => (
              <ComboboxItem key={fruit.value} value={fruit}>
                {fruit.label}
              </ComboboxItem>
            ))}
          </ComboboxList>
        </ComboboxContent>
      </Combobox>
    </div>
  )
}

export const Multiple: Story = {
  render: function Render() {
    const anchor = useComboboxAnchor()
    return (
      <div ref={anchor} className="w-80">
        <Combobox multiple items={FRUITS} itemToStringValue={item => item.value}>
          <ComboboxChips>
            <ComboboxValue>
              {(value: typeof FRUITS) => (
                <>
                  {value?.map(item => (
                    <ComboboxChip key={item.value}>{item.label}</ComboboxChip>
                  ))}
                  <ComboboxChipsInput placeholder="Add…" />
                </>
              )}
            </ComboboxValue>
          </ComboboxChips>
          <ComboboxContent anchor={anchor}>
            <ComboboxList>
              <ComboboxEmpty>No matches</ComboboxEmpty>
              {FRUITS.map(fruit => (
                <ComboboxItem key={fruit.value} value={fruit}>
                  {fruit.label}
                </ComboboxItem>
              ))}
            </ComboboxList>
          </ComboboxContent>
        </Combobox>
      </div>
    )
  }
}
