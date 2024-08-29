class User < ApplicationRecord
  belongs_to :account
  has_many :enrollments, dependent: :destroy

  devise :magic_link_authenticatable, :rememberable

  validates :email, presence: true, uniqueness: true

  enum role: %i[admin employee]

  validate :date_in_the_correct_format
  attr_accessor :invalid_date_added

  def avatar_initials
    candidate = name
    candidate = email if candidate.blank?
    last, first = *candidate.reverse.split(/\s+/, 2).collect(&:reverse)
    return last[0].upcase if first.nil?

    "#{first[0]}#{last[0]}".upcase
  end

  def date_of_birth=(value)
    @invalid_date_added = false
    if value.is_a?(String) && !value.blank?
      begin
        write_attribute(:date_of_birth, Date.strptime(value, '%m/%d/%Y'))
      rescue ArgumentError => e
        @invalid_date_added = true
      end
    else
      super(value)
    end
  end

  def date_in_the_correct_format
    errors.add(:date_of_birth, 'Must be in the MM/DD/YYYY format') if @invalid_date_added
  end
end
