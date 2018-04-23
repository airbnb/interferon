require 'spec_helper'
require 'interferon/group_sources/filesystem'

describe Interferon::GroupSources::Filesystem do
  let(:fs_loader) { Interferon::GroupSources::Filesystem.new('paths' => ['/tmp']) }

  describe 'list_groups' do
    context 'with basic groups' do
      before do
        group_a = double
        expect(File).to receive(:read).with('group_a.yaml').and_return('group_a_text')
        expect(Psych).to receive(:parse).and_return(group_a)
        expect(group_a).to receive(:to_ruby).and_return('name' => 'group_a',
                                                        'people' => %w[Alice Bob])

        group_b = double
        expect(File).to receive(:read).with('group_b.yaml').and_return('group_b_text')
        expect(Psych).to receive(:parse).and_return(group_b)
        expect(group_b).to receive(:to_ruby).and_return('name' => 'group_b',
                                                        'people' => %w[Carol Dave])
      end

      it 'loads groups defined by YAML' do
        expect(Dir).to receive(:glob).and_return(['group_a.yaml', 'group_b.yaml'].each)

        groups = fs_loader.list_groups
        expect(groups).to eq('group_a' => %w[Alice Bob], 'group_b' => %w[Carol Dave])
      end

      it 'allows groups to be aliased in YAML' do
        expect(Dir).to receive(:glob).and_return(['group_a.yaml',
                                                  'group_b.yaml',
                                                  'group_c.yaml',].each)
        group_c = double
        expect(File).to receive(:read).with('group_c.yaml').and_return('group_c_text')
        expect(Psych).to receive(:parse).and_return(group_c)
        expect(group_c).to receive(:to_ruby).and_return('name' => 'group_c',
                                                        'alias_for' => 'group_b')

        groups = fs_loader.list_groups
        expect(groups).to eq('group_a' => %w[Alice Bob],
                             'group_b' => %w[Carol Dave],
                             'group_c' => %w[Carol Dave])
      end

      it 'skips bad aliases in YAML' do
        expect(Dir).to receive(:glob).and_return(['group_a.yaml',
                                                  'group_b.yaml',
                                                  'group_c.yaml',].each)
        group_c = double
        expect(File).to receive(:read).with('group_c.yaml').and_return('group_c_text')
        expect(Psych).to receive(:parse).and_return(group_c)
        expect(group_c).to receive(:to_ruby).and_return('name' => 'group_c',
                                                        'alias_for' => 'group_d')

        groups = fs_loader.list_groups
        expect(groups).to eq('group_a' => %w[Alice Bob],
                             'group_b' => %w[Carol Dave])
      end
    end
  end
end
