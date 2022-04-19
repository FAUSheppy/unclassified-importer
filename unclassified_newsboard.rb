require "mysql2"
require File.expand_path(File.dirname(__FILE__) + "/../base.rb")
require File.expand_path(File.dirname(__FILE__) + "/../base/uploader.rb")
require 'htmlentities'

class ImportScripts::UnClassNews < ImportScripts::Base

  DB_HOST = "localhost"
  DB_NAME = "forum"
  DB_PW = "PASSWORD"
  DB_USER ="forum"

  # Site settings
  SiteSetting.disable_emails = true

  def initialize
    super
    @htmlentities = HTMLEntities.new
    begin
      @client = Mysql2::Client.new(
        host: DB_HOST,
        username: DB_USER,
        password: DB_PW,
        database: DB_NAME
      )
    rescue Exception => e
	  puts "cannot connect to databse"
      exit
    end
  end

  def mysql_query(sql)
    @client.query(sql)
  end

  def execute
    import_users
    import_categories
    import_topics
    import_posts
    update_tl0
  end

#########################################################################################################################################################

  def import_users
    puts '', "creating users"
    table = "fsi_Users"
    total_count = mysql_query("SELECT count(*) count FROM fsi_Users;").first['count']

      results = mysql_query("SELECT 
             ID          	as id,
             Name       	as username,
             Password   	as import_pass,
             RegDate        as created_at,
             ValidatedEMail as email,
             Language   	as locale,
             About      	as description,
             Location   	as location,
             Homepage   	as hp
             FROM fsi_Users
             order by id ASC;"
        )
      puts 
      return if results.size < 1

      create_users(results, total: total_count) do |user|
              if user['email'].blank?
                puts "Some black dude had no mail, shoot him"
                next
              end
        { id: user['id'],
		  custom_fields: {import_pass: user['import_pass']},
          email: user['email'].gsub("@","we") + "@atlantishq.de",
          username: user['username'],
          active: true,
          #name: user['username'],
          created_at: user['created_at'] == nil ? 0 : Time.zone.at(user['created_at']),
          website: user['hp'],
          #password: user['password'],
          #last_seen_at: user['DateLastActive'] == nil ? 0 : Time.zone.at(user['DateLastActive']),
          location: user['location'],
          post_create_action: proc do |user|
            import_avatar(user,results)
    	  end
        }
    end
  end
 
#########################################################################################################################################################

def import_avatar(user_object, user_table_query_results)
        user = user_object
        row = user_table_query_results

        id = row[:ID]
        avatar_name = row[:Avatar]
        photo_name = row[:Photo]
        url = "https://fsi.cs.fau.de/forum/unb_lib/upload/"
        avatar_name.to_s.empty? ? name = avatar_name : name = photo_name
        photo_name.to_s.empty?  ? return
        url += name

        ## download avatar
        avatar_file = FileHelper.download(path)
        rescue StandardError => err
                warn "Avatar kaputt, alles scheiße"
                return
        end

        begin
                ## upload new image
                upload = Uploader.create_upload(user_id, avatar_file, name)

                if upload.present? && upload.persisted?
                        user.import_mode = false
                        user.create_user_avatar
                        user.import_mode = true
                        user.user_avatar.update(custom_upload_id: upload.id)
                        user.update(uploaded_avatar_id: upload.id)
                else
                        puts "Failed to upload avatar for user #{user.username}:"
                        puts upload.errors.inspect if upload
                end
        rescue SystemCallError => err
                Rails.logger.error("Could not import avatar for user #{user.username}: #{err.message}")
        end
end

#########################################################################################################################################################

  def import_categories
    puts "", "importing categories..."
    
    categories = mysql_query("SELECT 
                              ID as id,
                              sort as position,
                              Parent as parent,
                              Name as name,
                              Flags as flags,
                              Description as desc
                              FROM fsi_Forums
                              ORDER BY id ASC
                            ")#.to_a <--- dfg?
    create_categories(categories) do |category|
      {
        id: category['id'],
        name: CGI.unescapeHTML(category['name']),
        description: CGI.unescapeHTML(category['desc']),
        parent_category_id: category['parent'],
        position: category['position'],
        # flag 1 means it's "pseudo-forum" that only has other subforums but no topics
        show_subcategory_list: category['flags'] == 1 ? true : false
      }
    end
  end

#########################################################################################################################################################

  def import_topics
    puts "", "importing topics..."

    total_count = mysql_query("SELECT count(*) count FROM fsi_Threads;").first['count']

    discussions = mysql_query("SELECT 
                                ID as id,
                                Forum as category_id,
                                LastPostDate as updated_at,
                                Subject as subject,
                                Desc as desc,
                                Date as created_at,
                                User as creator_user_id,
                                Views as views,
                                Question as poll_q
                                FROM fsi_Threads;") 


      break if discussions.size < 1
      
      create_posts(discussions, total: total_count) do |discussion|

         ### POLLS ###
         poll_rows = mysql_query("SELECT 
                                Thread as  t,
                                Sort as sort,
                                Title as poll_title,
                                Votes as vote_count,
                                FROM fsi_PollVotes)
                                WHERE Thread ="+discussions['id']+";" )
        # TODO concatinate string for raw for inline poll # 
        # raw = "[poll]" + TODO + [\poll]
        # TOD how the fuck does one save who votes and how many votes per option there are????

        raw = raw + clean_up(discussion['Body'])

        {
          id: "discussion#" + discussion['id'].to_s,
          user_id: user_id_from_imported_user_id(discussion['creator_user_id']) || Discourse::SYSTEM_USER_ID,
          title: discussion['subject'].gsub('\\"', '"') + "** " + discussion['desc'] +" **\n",
          category: category_id_from_imported_category_id(discussion['category_id']),
          created_at: Time.zone.at(discussion['created_at']),
          last_posted_at: Time.zone.at(discussion['updated_at']),
          updated_at: Time.zone.at(discussion['updated_at']),
          views: discussion['views']
        }
      end
    end

#########################################################################################################################################################

  def import_posts
    puts "", "importing posts..."

    # todo save that a user already voted on a post
    # todo attachements, lol
    # FIXME no idea what those 'Options' do

    total_count = mysql_query("SELECT count(*) count FROM fsi_Posts;").first['count']
      comments = mysql_query("SELECT
                                ID as id,
                                Thread as topic_id,
                                ReplyTo as reply_to_post_number,
                                Date as created_at,
                                EditUser as last_editor_id,
                                EditDate as updated_at,
                                EditCount as ???,
                                EditReason as edit_reason,
                                User as user_id,
                                Subject as subject,
                                Msg as body_text,
                                Options as ???,
                                AttachFile as ???,
                                AttachFileName as ???,
                                AttachDLCount as ???,
                                SpamRating as spam_count
                                FROM fsi_Posts;")

      break if comments.size < 1
      next if all_records_exist? :posts, comments.map { |comment| "comment#" + comment['CommentID'].to_s }

      create_posts(comments, total: total_count, offset: offset) do |comment|
        next unless t = topic_lookup_from_imported_post_id("discussion#" + comment['DiscussionID'].to_s)
        next if comment['body_text'].blank?
        raw = "**" + comment['subject'] + "**\n"
        raw = raw + clean_up(comment['body_text'])
        {
          id: "comment#" + comment['id'].to_s,
          topic_id: [:topic_id],
          reply_to_post_number: comment['reply_to_post_number'],
          created_at: Time.zone.at(comment['created_at']),
          last_editor_id: comment['last_editor_id'],
          updated_at: Time.zone.at(comment['updated_at']),
          edit_reason: comment['edit_reason'],
          user_id: user_id_from_imported_user_id(comment['user_id']) || Discourse::SYSTEM_USER_ID,
          like_count: 0,
          #last_editor_id: comment['last_editor_id'],
          raw: clean_up(raw),
          spam_count: comment['spam_count']
        }
      end
    end

#########################################################################################################################################################

  # FIXME this is so not working at all
  def import_attachments(user_id, post_id, topic_id = 0)
          # TODO rows = fetch from server
          return nil if rows.size < 1

          attachments = []

          rows.each do |row|
                  path = File.join(origin_path, row[:filename])
                  filename = CGI.unescapeHTML(row[:filename])
                  upload = @uploader.create_upload(user_id, path, filename)

                  if upload.nil? || !upload.persisted?
                          puts "Failed to upload #{path}"
                          puts upload.errors.inspect if upload
                  else
                          attachments << @uploader.html_for_upload(upload, filename)
                  end
          end

          return attachments
  end

#########################################################################################################################################################

  ## from mylittleforum.rb, nothing changed
  def clean_up(raw)
    return "" if raw.blank?

    # decode HTML entities
    raw = @htmlentities.decode(raw)

    # don't \ quotes
    raw = raw.gsub('\\"', '"')
    raw = raw.gsub("\\'", "'")

    raw = raw.gsub(/\[b\]/i, "<strong>")
    raw = raw.gsub(/\[\/b\]/i, "</strong>")

    raw = raw.gsub(/\[i\]/i, "<em>")
    raw = raw.gsub(/\[\/i\]/i, "</em>")

    raw = raw.gsub(/\[u\]/i, "<em>")
    raw = raw.gsub(/\[\/u\]/i, "</em>")

    raw = raw.gsub(/\[url\](\S+)\[\/url\]/im) { "#{$1}" }
    raw = raw.gsub(/\[link\](\S+)\[\/link\]/im) { "#{$1}" }

    # URL & LINK with text
    raw = raw.gsub(/\[url=(\S+?)\](.*?)\[\/url\]/im) { "<a href=\"#{$1}\">#{$2}</a>" }
    raw = raw.gsub(/\[link=(\S+?)\](.*?)\[\/link\]/im) { "<a href=\"#{$1}\">#{$2}</a>" }

    # remote images
    raw = raw.gsub(/\[img\](https?:.+?)\[\/img\]/im) { "<img src=\"#{$1}\">" }
    raw = raw.gsub(/\[img=(https?.+?)\](.+?)\[\/img\]/im) { "<img src=\"#{$1}\" alt=\"#{$2}\">" }
    # local images
    raw = raw.gsub(/\[img\](.+?)\[\/img\]/i) { "<img src=\"#{IMAGE_BASE}/#{$1}\">" }
    raw = raw.gsub(/\[img=(.+?)\](https?.+?)\[\/img\]/im) { "<img src=\"#{IMAGE_BASE}/#{$1}\" alt=\"#{$2}\">" }

    # Convert image bbcode
    raw.gsub!(/\[img=(\d+),(\d+)\]([^\]]*)\[\/img\]/im, '<img width="\1" height="\2" src="\3">')

    # [div]s are really [quote]s
    raw.gsub!(/\[div\]/mix, "[quote]")
    raw.gsub!(/\[\/div\]/mix, "[/quote]")

    # [postedby] -> link to @user
    raw.gsub(/\[postedby\](.+?)\[b\](.+?)\[\/b\]\[\/postedby\]/i) { "#{$1}@#{$2}" }

    # CODE (not tested)
    raw = raw.gsub(/\[code\](\S+)\[\/code\]/im) { "```\n#{$1}\n```" }
    raw = raw.gsub(/\[pre\](\S+)\[\/pre\]/im) { "```\n#{$1}\n```" }

    raw = raw.gsub(/(https:\/\/youtu\S+)/i) { "\n#{$1}\n" } #youtube links on line by themselves

    # no center
    raw = raw.gsub(/\[\/?center\]/i, "")

    # no size
    raw = raw.gsub(/\[\/?size.*?\]/i, "")

    ### FROM VANILLA:

    # fix whitespaces
    raw = raw.gsub(/(\\r)?\\n/, "\n")
      .gsub("\\t", "\t")

    unless CONVERT_HTML
      # replace all chevrons with HTML entities
      # NOTE: must be done
      #  - AFTER all the "code" processing
      #  - BEFORE the "quote" processing
      raw = raw.gsub(/`([^`]+)`/im) { "`" + $1.gsub("<", "\u2603") + "`" }
        .gsub("<", "&lt;")
        .gsub("\u2603", "<")

      raw = raw.gsub(/`([^`]+)`/im) { "`" + $1.gsub(">", "\u2603") + "`" }
        .gsub(">", "&gt;")
        .gsub("\u2603", ">")
    end

    # Remove the color tag
    raw.gsub!(/\[color=[#a-z0-9]+\]/i, "")
    raw.gsub!(/\[\/color\]/i, "")
    ### END VANILLA:

    return raw
  end
end
