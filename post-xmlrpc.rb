#!/usr/bin/ruby
# encoding: utf-8
#
# 写真ファイルを日付にリネームし、タイトルと内容を入力してtDiaryの記事として投稿する
#
# Copyright 2011 Kenshi Muto <kmuto@debian.org>
#
# Ruby: gtk2が必要
# サーバ: tDiary。xmlrpc.rbが動作するようにしておく
# コマンド: リモートアップロードの場合はsshが必要。
#          サムネールの作成にimagemagickが必要。
#          Picasaモードのときにはrmagick、picasa on railsが必要。
#
require 'rubygems'
require 'xmlrpc/client'
require 'fileutils'
require 'gtk2'
require "#{ENV["HOME"]}/.post-xmlrpc.rb"

def cook_post(uri, login, pass, title, img, content, postdate)
  proxy = XMLRPC::Client.new_from_uri(uri)
  # TODO: サーバ側xmlrpc.rbのblogger.newPostを改変し、publishが空でない場合にはそれを日付けと見なすようにする
  # Wikiスタイルを前提。imageプラグインを改変し、image_cookで適切なURLエントリを作るようにしている
  if @config["picasa"].nil?
    return proxy.call("blogger.newPost", "", "tdiary", login, pass, "[cooking] #{title}\n{{image_cook \"#{img}\"}}\n#{content}", postdate)
  else
    # picasaプラグインを利用
    return proxy.call("blogger.newPost", "", "tdiary", login, pass, "[cooking] #{title}\n{{picasa \"#{img}\", \"\"}}\n{{'<br clear=\"all\" />'}}\n#{content}", postdate)
  end
end

def counttest(filename, testcmd, picasa = nil)
  if @config["picasa"].nil?
    return counttest_remote(filename, testcmd)
  else
    return counttest_picasa(filename, @config["picasa_album"], picasa)
  end
end

def counttest_remote(filename, testcmd)
  count = 1
  while true
    IO.popen("#{@config["testcmd"]}#{filename} && echo yes") do |p|
      if p.readlines.size == 0
        return filename
      else
        count += 1
        if count == 2
          filename = filename.sub(".", "-#{count}.")
        end
        filename.sub!(/-\d+\./, "-#{count}.")
        sleep(1)
      end
    end
  end
end

def counttest_picasa(filename, albumname, picasa)
  albums = picasa.albums(:access => "public")
  albums.each do |album|
    if album.name == albumname
      photos = album.photos
      if photos.size > 0
        files = []
        photos.each do |photo|
          files.push(photo.title)
        end

        count = 1
        while true
          return filename unless files.include?(filename)
          count += 1
          filename.sub!(".", "-#{count}.") if count == 2
          filename.sub!(/-\d+\./, "-#{count}.")
        end
      else
        return filename
      end
      break
    end
  end
  return nil
end

def errorexit(msg)
    d = Gtk::MessageDialog.new(nil, Gtk::Dialog::Flags::MODAL, Gtk::MessageDialog::Type::ERROR, Gtk::MessageDialog::ButtonsType::CLOSE, msg)
    d.run
    d.destroy
    exit
end

def upload_picasa(imgfile, filename, picasa)
  img_data = open(imgfile, "rb").read
  photo = picasa.post_photo(img_data, :album => @config["picasa_album"],
                            :summary => "Upload from ruby api",
                            :title => filename,
                            :local_file_name => filename)
  return photo.url
end

def main
  # ここからmain
  picasa = nil
  url = nil
  
  if !@config["picasa"].nil?
    require "picasa"
    require "RMagick"
    require "tmpdir"
    
    @config["picasa_passwd"] = ENV["PICASA_PASSWD"] if @config["picasa_passwd"].nil?
    errorexit("パスワードが指定されていません。") if @config["picasa_passwd"].nil?
    
    picasa = Picasa::Picasa.new
    picasa.login(@config["picasa_username"], @config["picasa_passwd"])
    errorexit("Picasa にログインできません。") if picasa.picasa_session.auth_key.nil?
  end
  
  filename = ARGV.shift
  
  errorexit("ファイルが指定されていないか、該当ファイルが存在しません。") if filename.nil? || !File.exist?(filename)
  
  ftime = File.mtime(filename)
  
  newfilename = counttest(ftime.strftime("%Y-%m-%d.jpg"), @config["testcmd"], picasa)
  errorexit("ファイル名を決定できません。おそらくアルバムが適切ではありません。") if newfilename.nil?
  
  window = Gtk::Window.new
  window.set_title("#{filename}を#{newfilename}としてアップロード")
  window.set_default_size(600, 400)
  
  window.signal_connect("delete_event") {
    Gtk.main_quit
    false
  }
  
  window.signal_connect("destroy") {
    Gtk.main_quit
  }
  
  titletext = Gtk::Entry.new
  contenttext = Gtk::TextView.new
  contenttext.buffer.text = ""
  begin
    contenttext.accept_tab = false
  rescue
  end
  
  scrolled_win = Gtk::ScrolledWindow.new
  scrolled_win.border_width = 5
  scrolled_win.add(contenttext)
  scrolled_win.set_policy(Gtk::POLICY_AUTOMATIC, Gtk::POLICY_ALWAYS)
  
  button = Gtk::Button.new("書き込み")
  button.signal_connect("clicked") {
    if titletext.text.strip.empty? || contenttext.buffer.text.strip.empty?
      d = Gtk::MessageDialog.new(window, Gtk::Dialog::Flags::MODAL, Gtk::MessageDialog::Type::ERROR, Gtk::MessageDialog::ButtonsType::CLOSE, "タイトルまたは内容が書き込まれていません。")
      d.run
      d.destroy
    else
      begin
        FileUtils.mv(filename, "#{@config["pictdir"]}/#{newfilename}") if filename != "#{@config["pictdir"]}/#{newfilename}"
        
        if @config["picasa"].nil?
          fork {
            # TODO: ネイティブで変換したほうがいい
            exec("convert", "-geometry", "#{@config["thumbsize"]}", "#{@config["pictdir"]}/#{newfilename}", "#{@config["thumbdir"]}/#{newfilename}")
          }
          Process.waitall
          
          # フル画像とサムネールのアップロード
          IO.popen(@config["putcmd"].gsub("%OFILE", "#{@config["pictdir"]}/#{newfilename}").gsub("%DFILE", newfilename)) do |p|
            puts p.readlines.join("\n")
          end
          IO.popen(@config["putthumbcmd"].gsub("%OFILE", "#{@config["thumbdir"]}/#{newfilename}").gsub("%DFILE", "#{newfilename}")) do |p|
            puts p.readlines.join("\n")
          end
        else
        # Picasa
          uploadtarget = "#{@config["pictdir"]}/#{newfilename}"
          imgs = Magick::ImageList.new(uploadtarget)
          if imgs[0].columns > @config["picasa_maxwidth"]
            ratio = @config["picasa_maxwidth"].to_f / imgs[0].columns.to_f
            height = (imgs[0].rows.to_f * ratio).to_i
            img2 = imgs[0].resize(@config["picasa_maxwidth"], height)
            Dir.mktmpdir do |dir|
              img2.write("#{dir}/resized.jpg")
              uploadtarget = "#{dir}/resized.jpg"
              newfilename = upload_picasa(uploadtarget, newfilename, picasa)
            end
          else
            newfilename = upload_picasa(uploadtarget, newfilename, picasa)
          end
          errorexit("ファイル名を取得できません。何か問題が起きています。") if newfilename.nil?
          # サムネールパートを挿入
          newfilename = newfilename.sub(/\A(.+\/)/, '\1' + "s#{@config["thumbsize"]}/")
        end
        
        # 記事投稿
        puts cook_post(@config["posturi"], @config["username"], @config["password"], titletext.text.strip, newfilename, contenttext.buffer.text.strip, ftime.strftime("%Y%02m%02d"))
        Gtk.main_quit
      rescue Exception=>e
        puts e
        puts
        puts titletext.text.strip
        puts contenttext.buffer.text.strip
        puts newfilename
        Gtk.main_quit
      end
    end
  }
  
  cancel = Gtk::Button.new("キャンセル")
  cancel.signal_connect("clicked") {
    Gtk.main_quit
  }
  
  hbox = Gtk::HBox.new(false, 0)
  hbox.add(button)
  hbox.add(cancel)
  
  pixbuf = Gdk::Pixbuf.new(filename)
  
  maxwidth = Gdk::Screen.default.width
  maxheight = Gdk::Screen.default.height
  
  height = pixbuf.height
  width = pixbuf.width
  
  # 縮小
  if height > maxheight * @config["ratio"]
    height = maxheight * @config["ratio"]
    width = width * (height / pixbuf.height)
  end
  
  resizedimg = pixbuf.scale(width, height)
  pixbuf = nil
  
  image = Gtk::Image.new(resizedimg)
  
  vbox = Gtk::VBox.new(false, 0)
  vbox.add(titletext)
  vbox.add(scrolled_win)
  vbox.add(hbox)
  vbox.add(image)
  
  window.add(vbox)
  window.border_width = 10
  window.show_all
  
  Gtk.main
end

main
