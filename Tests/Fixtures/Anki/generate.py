# Generated with official PyPI anki==26.9.3. Fictional content only.
from pathlib import Path
from tempfile import TemporaryDirectory
import base64, wave
from anki.collection import Collection
from anki.import_export_pb2 import ExportAnkiPackageOptions, ExportLimit
out=Path(__file__).resolve().parent
with TemporaryDirectory(prefix='anki-export-fixture-') as tmp:
    col=Collection(str(Path(tmp)/'collection.anki2'))
    deck=col.decks.id('架空の教材::日本語')
    import struct, zlib
    def chunk(kind, payload):
        return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 80, 40, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress((b'\0' + b'\xff\0\0' * 80) * 40)) + chunk(b'IEND', b'')
    col.media.write_data('fixture.png', png)
    audio=Path(tmp)/'fixture.wav'
    with wave.open(str(audio),'wb') as w:
        w.setnchannels(1);w.setsampwidth(2);w.setframerate(8000);w.writeframes(b'\0\0'*8000)
    col.media.write_data('fixture.wav',audio.read_bytes())
    samples=[('Basic',['架空の問題<img src="fixture.png">[sound:fixture.wav]','架空の解答']),('Basic (and reversed card)',['架空の表','架空の裏']),('Cloze',['{{c1::赤}}と{{c2::青}}','架空の補足'])]
    for kind,fields in samples:
        model=col.models.by_name(kind)
        if not model: raise RuntimeError(kind)
        note=col.new_note(model);note.fields=fields;note.tags=['架空タグ','日本語'];col.add_note(note,deck)
    for legacy in [False,True]:
        name='latest-media.apkg' if not legacy else 'legacy2-media.apkg'
        col.export_anki_package(out_path=str(out/name),options=ExportAnkiPackageOptions(with_media=True,legacy=legacy,with_scheduling=False),limit=ExportLimit())
    col.export_anki_package(out_path=str(out/'latest-no-media.apkg'),options=ExportAnkiPackageOptions(with_media=False,legacy=False,with_scheduling=False),limit=ExportLimit())
    print('small source notes/cards:',col.note_count(),col.card_count())
    col.close()
with TemporaryDirectory(prefix='anki-vocab-fixture-') as tmp:
    col=Collection(str(Path(tmp)/'collection.anki2'))
    model=col.models.new('架空の7フィールド語彙')
    for name in ['Word','Meaning','EnglishExample','JapaneseExample','WordAudio','SentenceAudio','PartOfSpeech']:
        col.models.add_field(model,col.models.new_field(name))
    template=col.models.new_template('語彙')
    template['qfmt']='<p>{{EnglishExample}}</p><h2>{{Word}}</h2>{{WordAudio}}'
    template['afmt']='{{FrontSide}}<hr id=answer><p>{{JapaneseExample}}</p><p>{{Word}}：{{Meaning}}（{{PartOfSpeech}}）</p>{{SentenceAudio}}'
    col.models.add_template(model,template);col.models.add(model)
    for i in range(1900):
        deck=col.decks.id(f'架空の語彙::Lesson{i//100+1:02}')
        note=col.new_note(model)
        note.fields=[f'word{i}',f'架空の意味{i}',f'This is fictional example {i}.',f'これは架空の例文{i}です。','[sound:fixture-word.mp3]','[sound:fixture-sentence.mp3]','名詞']
        note.tags=['架空タグ',f'Lesson{i//100+1:02}'];col.add_note(note,deck)
    col.export_anki_package(out_path=str(out/'latest-vocabulary-1900.apkg'),options=ExportAnkiPackageOptions(with_media=True,legacy=False,with_scheduling=False),limit=ExportLimit())
    print('vocabulary source notes/cards:',col.note_count(),col.card_count())
    col.close()

# Rewrap the real exporter payload to exercise ZIP descriptors and optional extra fields.
import io, zipfile
class NonSeekable(io.BytesIO):
    def seekable(self): return False
    def seek(self, *args): raise io.UnsupportedOperation("no seek")
output = NonSeekable()
with zipfile.ZipFile(out / "latest-media.apkg") as source, zipfile.ZipFile(output, "w") as target:
    for name in source.namelist():
        info = zipfile.ZipInfo(name); info.compress_type = zipfile.ZIP_DEFLATED
        info.extra = b"\xfe\xca\x02\x00OK"
        target.writestr(info, source.read(name))
(out / "latest-descriptor-extra.apkg").write_bytes(output.getvalue())
# Python 3.14 standard-library zstd; tiny input exceeding the decoder's ratio budget.
from compression import zstd
(out / "expansion-limit.zst").write_bytes(zstd.compress(b"A" * 2_000_000))
